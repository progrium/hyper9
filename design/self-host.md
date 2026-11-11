---
id: 10
slug: self-host
title: Self-hosting
status: implemented
created: 2026-11-03
authors: [progrium]
depends: []
areas: [kern, vmm, tests]
branch: [main]
---

# Proposal: self-hosting

Nov 3, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

The 9front compilers, linkers, and mk already run inside h9 and rebuild all of `/sys/src`. This proposal makes that a tested, documented capability. It also adds what acid needs to debug a live process: `/proc/n/mem`, `regs`, `fpregs`, and `text`, the `ctl` stop and start messages, and breakpoint traps.

## Background

This was milestone M6 in SPEC.md, before milestones became proposals ([#1](proposals.md)). Self-hosting is one of SPEC.md's goals, and a source of test binaries for other proposals.

**What runs today.** These were measured on 2026-11-04 on an M3 Max with HVF, the pinned 9front 11952 root, and its source from `.local/src/9front` (which `scripts/fetch.sh` checks out at the same revision).

| Build | Result | Time |
| --- | --- | --- |
| `7c ls.c; 7l -o 7.ls ls.7` in the cwd | Runs; byte-identical to `/arm64/bin/ls` | 0.03 s |
| `mk` in a directory using `/sys/src/cmd/mkone` | Works | 0.04 s |
| `cd /sys/src/cmd && mk ls.7 cat.7 && mk 7.ls 7.cat` | Both byte-identical to the shipped binaries | 0.2 s |
| `hoc` (yacc), `rc`, `acid`, `7c` (with `../cc/cc.a7`) | Build | 0.1 to 0.5 s each |
| `libbio` into the cwd (`mk 'LIB=…'`), with the root read-only | Works | |
| `cd /sys/src/libc && mk install`, root writable | Works | 3.9 s |
| `cd /sys/src/cmd && mk all` | Works, 3889 lines of output | 60 s |
| `cd /sys/src && mk install` (libs, ape, acme, cmd, games) from pristine source | Exit 0 | 49 to 111 s (Debug h9); 60 s, or 33 s with `NPROC=8` (ReleaseFast h9) |
| `cd /sys/src/9/arm64 && mk` | Builds `9qemu` and `9qemu.u` | 4.4 s |
| `objtype=amd64`: `mk libs`, then `6.ls` | Builds; runs on the emulator backend | 8.6 s |

After the full rebuild, 701 of the root's 704 arm64 binaries are byte-identical to the shipped ones. The other three (`gs`, `cwfs64x`, `audio/mp3enc`) differ only in embedded build dates (`__DATE__` and version strings). The library archives differ only in `ar` member dates.

**Bugs the experiment found, fixed alongside this draft:**

- `kern.setArgs` overflowed when an argv filled the 128-byte `/proc/n/args` buffer exactly and more arguments followed. That panicked h9 on libc's `ar vu` line. A test now covers the exact fit.
- drawterm's `libc/lock.c` was built without `PTHREAD`. Its non-pthread `unlock` is a plain store with no release ordering. On arm64 another thread could take a `Lock` before seeing the writes made under it, which corrupted QLock wait queues. Under contention a process then slept forever: `mk` with `NPROC` greater than 1 hung in about 1 run in 8, and 8 processes writing a shared `/env` hung in about 3 runs in 4. `build.zig` now passes `-DPTHREAD`, as drawterm's `Make.linux` does, and an integration case runs that `/env` workload. Windows keeps drawterm's `Make.win64` flags.

So the compilers, linkers, and mk need no syscall that h9 lacks, and no dependency on [segattach](segattach.md) or [semaphores](semaphores.md).

**Gaps left:**

1. **Parallel mk isn't automatic.** `mk` takes `$NPROC`, which 9front's `termrc` sets from `wc -l /dev/sysstat`. h9 doesn't set it, and drawterm's `/dev/sysstat` reads empty, so builds run one job at a time unless the user passes `--env NPROC=n`.
2. **The source tree isn't in the root.** `scripts/mkroot.py` leaves out `/sys/src` unless given `--src`. The fetched checkout at `.local/src/9front/sys/src` is the same revision, and it can be bound in, as the experiments did with `bind -a /mnt/term/<checkout>/sys /sys`.
3. **Installing needs a writable root.** `mk install` writes `/arm64/bin` and `/arm64/lib`, so it needs `--writable "$H9ROOT"`. Building without installing works against the read-only root, with output in the cwd.
4. **The root has no amd64 libraries.** The arm64 root ships `/amd64/include` and `/amd64/mkfile` but no `/amd64/lib`. So `objtype=amd64` builds have to start with `mk libs`, which works.
5. **acid can't attach.** With a binary alone it reads symbols (`symbols("main")` works). Attaching to a process fails at `setproc: open /proc/2/mem: file does not exist`. h9's devproc serves `args`, `ctl`, `fd`, `note`, `noteid`, `notepg`, `ns`, `ppid`, `segment` ([segattach](segattach.md)), `status`, and `wait`. acid and libmach also open `mem`, `regs`, `fpregs`, and `text` (`cmd/acid/proc.c`, `libmach/map.c`). They write `ctl` messages h9 doesn't take (`stop`, `start`, `waitstop`, `startstop`), and `hang` is recorded but ignored.
6. **Breakpoints kill the process.** A `BRK` (libmach's arm64 breakpoint is `0xD4200000`) arrives at h9 as an unclassified exception. h9 reports it as `sys: trap: fault exec addr=…` and the process dies. 9front posts `sys: breakpoint` for exception classes 0x30, 0x31, and 0x3C. The amd64 equivalent is `INT3` (vector 3).

## Proposal

### Building

**NPROC.** The guest environment gains `NPROC`, set to the vCPUs the machine can run at once: `--cpus` if given, otherwise the host's CPU count. 9front's `termrc` derives it from the same thing. `--env NPROC=n` overrides it, as for any default variable. `/dev/sysstat` stays empty, since its other fields would be invented.

**Source.** `/sys/src` comes from the root tree, as on 9front. `scripts/mkroot.py --src` already keeps it. The README documents two ways to work with source:

- Building in the cwd against the read-only root, which needs nothing extra: `h9 mk` in a copy of a source directory.
- Rebuilding the userland in place: `h9 --writable "$H9ROOT" --rc 'cd /sys/src && mk install'`, on a root built with `--src`. The README recommends a copy of the root for this (`cp -cR` makes an APFS clone on macOS in about a second), because it replaces the root's binaries.
- Cross-building for amd64: `objtype=amd64 mk libs` once in `/sys/src` on such a writable copy, then `objtype=amd64 mk` as usual. The pinned arm64 root has no `/amd64/lib`, and building it takes about 9 s.

No new flag binds source; `--readable` and `--ns` already can.

**Build products.** Nothing here changes `exec` or devfs. The compilers' syscall mix is file I/O. Building `cmd/rc` makes 9931 calls: 3193 `pread`, 2399 `close`, 1282 `open`, 1175 `create`, and 1119 `pwrite`, with 64 `exec`s. At these speeds devfs isn't the bottleneck (see Rationale).

### Debugging

devproc gains 9front's debugging files. They're served from h9's process records, as the others are, and looked up in the caller's machine only.

| File | Read | Write |
| --- | --- | --- |
| `mem` | The process's memory at the offset, through its address space, as `procctlmemio` does. Unmapped addresses fail with "bad address". | Allowed only while the process is stopped, as on 9front. Writes go to the backing pages; a write into text copies the text segment for that process first (9front's `txt2data`), so a breakpoint never lands in a sibling's text. |
| `regs` | The saved `Ureg` (arm64 or amd64, as `src/arch` defines it), while the process is stopped or in a syscall. Otherwise "no register set". | While stopped: written into the saved Ureg through `arch.sanitize`, so the guest can't set privileged state, as with `noted`. |
| `fpregs` | `vmm.Extra` laid out as 9front's `FPsave`: on arm64, `regs[32][2]` then `control` and `status` (520 bytes, libmach's `FPREGSIZE`); on amd64, the FXSAVE layout. | While stopped. |
| `text` | Opens the process's image (the file it executed), so acid's `checkqid` compares qids. | Not allowed. |
`/proc/n/segment` is served already ([segattach](segattach.md)), in 9front's format with `Stack` first, as libmach's `stacktop` needs.

**Code caches.** A `mem` write to an executable page has to reach the guest's next instruction fetch. acid rewrites the same text addresses repeatedly: each `step` plants breakpoints at the following instructions and then restores them. Only the first write to shared text changes the address space (the copy). Later writes to the now-private copy don't, so the address space gains a `codeChanged(va, len)` call, which devproc makes after every write to an executable page. emu then drops its translated blocks before the next run, as `sync` does after a remap. hvf sets `shared.flush`, so the shim invalidates the I-cache before the next entry.

**Stopping.** A process can be stopped at four points: entering a syscall, returning from one, delivering a note, and exiting the guest on a breakpoint or fault. A stopped process parks on its own kernel thread, in a drawterm `sleep` on its record. It holds no pooled vCPU and no `--cpus` slot, like a process blocked in a syscall. Its Ureg and Extra are copied to the record when it stops and loaded back when it resumes, so readers on other threads never touch a vCPU. `ctl` gains:

| Message | Effect |
| --- | --- |
| `stop` | Stop at the next stop point, and wait until it's stopped. |
| `waitstop` | Wait until it stops on its own. |
| `start` | Resume a stopped process. |
| `startstop` | Resume, then wait for the next stop. |
| `hang` / `nohang` | Already recorded; now `exec` stops the process before its first instruction when set, as 9front's `sysexec` does. acid's `new()` depends on it. |

The status state of a stopped process reads `Stopped`, and of a waiting debugger `Stopwait`, as on 9front. A note posted to a stopped process is queued, and `kill`, `--timeout`, and machine teardown still end it. A stopped process can't hold up teardown, because `procinterrupt` wakes the sleep. 9front's `traceme`, `startsyscall`, `profile`, `wired`, `pri`, and real-time messages aren't added; they fail with "bad control message", as now.

**Breakpoints.** The hvf and emu backends classify `BRK` (ESR class 0x3C on arm64) and `INT3` (vector 3 on amd64) as a new `vmm.Exit.breakpoint`. The KVM and WHP backend proposals get the same exit. The machine posts `sys: breakpoint` with the debug flag, as 9front's trap table does. Without a debugger or a note handler, the process dies with that note, so `acid -l truss` and acid's `bpset` work. The PC is left at the `BRK` instruction on arm64, and after `INT3` on amd64, as on 9front, since acid's per-architecture code adjusts it.

### Tests

The integration tests use the root tree, which normally has no `/sys/src`. The self-host cases look for source at `/sys/src` in the root, and otherwise at `H9_TEST_SRC` (the build passes `.local/src/9front/sys`, or `-Dsrc=DIR`). They skip when neither exists. They build into a scratch directory, never into the root.

## Rationale

**No new flags for source or installing.** A `--src DIR` flag would only save writing a bind, and `--writable "$H9ROOT"` already makes installs explicit and visible in `--print`. Installing into the root by default would quietly make every run able to replace the root's binaries.

**The root as it is, not a separate source image.** `mkroot.py --src` already exists, and the checkout `fetch.sh` makes is the same revision. A third copy would add nothing.

**NPROC from the CPU limit, not `/dev/sysstat`.** Filling `/dev/sysstat` would mean making up per-CPU counters (context switches, interrupts, syscalls) that h9 doesn't track. The only consumer that matters, `termrc`'s `NPROC` line, gets the same value directly.

**Leaving devfs alone.** SPEC.md asked whether the host-tree root needs a faster read path for exec and compilers. With a ReleaseFast h9, the whole userland rebuilds in 60 s serially, or 33 s with 8 jobs. Each `exec` already reads the image in one pass (`Machine.readFile`). A cache or a second read path would add a correctness surface (staleness when the host edits a file) for a gain these numbers don't need. If a profile later shows devfs dominating, that's performance work without a behaviour change, so it doesn't need a proposal.

**Stopping on the process's own thread.** One alternative is to freeze a process by holding its vCPU or pausing its host thread. But reading registers from another thread would then need backend calls on a vCPU the reader doesn't own, which HVF forbids. Parking at the existing stop points, with the state copied to the record, needs no backend support and works the same on every backend. A process spinning in pure guest code with no syscalls still stops promptly: `stop` kicks the vCPU, as note delivery and `--timeout` do. hvf's kick is `hv_vcpus_exit`, and emu's is `uc_emu_stop`, retried until the run sees it. Neither waits for a timer tick. `tests/backends.zig` already covers both against a `b .` / `jmp .` loop.

**Breakpoint stepping, not hardware single-step.** acid's `step` plants breakpoints at libmach's `follow(*PC)` and runs `startstop`, on every architecture. That's how 9front itself steps, so h9 needs nothing more. Hardware single-step (`MDSCR_EL1.SS`, `RFLAGS.TF`) would need support in each backend and would make h9 behave differently from 9front. One limitation is inherited: libmach's `arm64foll` doesn't decode `TBZ` and `TBNZ`, so stepping over a taken one runs on to the next stop. That's a fix for 9front's libmach, not h9.

**No watchpoints or profiling.** 9front's own arm64 kernel stubs out `setupwatchpts`, and acid's `wpflush` checks `access(".../watchpt")` before writing, so leaving the file out matches 9front on arm64. Only `tprof` reads `profile`. Either can come in a later proposal if someone needs it.

**amd64 libraries built by the user, not by `mkroot.py`.** Building `/amd64/lib` in `mkroot.py` would make building the root depend on a working h9. `mk libs` already works and takes about 9 s, so the README documents it instead.

**Copy-on-write text for `mem` writes.** Text segments are shared among every process running the same image in a process tree (`Segs.fork`). Writing a breakpoint into shared text would make siblings trap too. 9front avoids this by turning text into a private data segment on the first write (`txt2data`), and h9 does the same.

**No gdb stub.** acid is the native debugger and needs only devproc. A gdb remote stub is a separate interface that isn't needed for this proposal; SPEC.md already lists it as absent.

**Not fixing the build-date differences.** `gs`, `cwfs64x`, and `mp3enc` embed `__DATE__`. Reproducible builds would mean changing the compiler's notion of the date, which belongs in 9front, not h9. The test compares binaries that don't embed dates.

## Compatibility

- **Guest environment:** gains `NPROC`. A guest that read an empty `$NPROC` and treated it as 1 now runs jobs in parallel. `--env NPROC=1` restores the old behaviour.
- **`/proc/n`:** gains `mem`, `regs`, `fpregs`, and `text`. `ctl` gains `stop`, `start`, `waitstop`, and `startstop`, and `hang` takes effect.
- **Notes:** a `BRK` or `INT3` posts `sys: breakpoint` instead of `sys: trap: fault exec addr=…`. Programs that matched the old string weren't matching 9front's.
- **vmm interface:** gains `Exit.breakpoint` and `AddressSpace.codeChanged`, which need a proposal per README.md; it's this one. Each backend maps its own exception class and invalidates its own code cache, and every backend proposal (kvm, whp) inherits both.
- **CLI flags, exit codes, and `Machine.Options`:** unchanged.
- **Sandbox defaults:** unchanged. The root stays read-only by default, so `mk install` fails with "permission denied" unless the user passes `--writable "$H9ROOT"`.
- **Root tree:** unchanged; `--src` stays optional.
- **`third_party/`:** unchanged. The `PTHREAD` fix is a build flag, not a vendor edit.

## Security

- **Process memory and registers** are reachable only for processes in the caller's own machine. devproc already resolves every pid in the caller's machine, so a machine can't read or write another machine's guest memory, and nothing reaches host memory. `mem` translates through the target's guest address space, and so it can reach only pages mapped there. Unmapped and kernel-range addresses fail. The `GuestBuf` rules (seam rule 7) apply to the reader's buffer.
- **Register writes** pass through `arch.sanitize`, so a guest can't set privileged PSTATE or RFLAGS bits, or segment selectors, through `regs`. This is the same filter `noted` applies.
- **Permissions:** as on 9front, any process in the machine can open another's debug files, since every process runs as the machine's single user. A sandboxed guest could already kill its siblings through `ctl`. Reading their memory adds nothing outside the machine.
- **Writing text** copies the segment first, so an image shared by siblings is never modified for them, and the host file is never written. Images are read once into guest pages.
- **Stopped processes** can't outlive the machine. `--timeout`, `kill`, and teardown interrupt the sleep, and the `--pids` and `--memory` caps still count them.
- **Writable root:** `--writable "$H9ROOT"` lets the guest replace any binary in the root, which later runs then execute. That's the user's explicit choice. The README recommends a disposable copy, and `--print` shows the writable path.

## Done criteria

Demos, registered with `addDemo(b, &demos, "self-host", …)`:

- [x] `zig build proposal -Dp=self-host` rebuilds `/sys/src/cmd/ls` in a scratch directory with the stock `cmd/mkfile`, runs the result, and checks it's byte-identical to `/arm64/bin/ls`.
- [x] `h9 --rc 'sleep 5 & acid $apid' <<<'stk()'` (or the equivalent rc script) prints a stack trace through `main` and `sleep`.

Integration cases, tagged `[self-host]`:

- [x] `test "7c and 7l build ls in the cwd, and it runs [self-host]"`
- [x] `test "mk builds ls and cat with the stock cmd/mkfile, byte-identical to the root's [self-host]"`
- [x] `test "mk builds a library into the cwd against the read-only root [self-host]"`
- [x] `test "mk install into a read-only root fails with permission denied [self-host]"`
- [x] `test "NPROC defaults to the vCPU limit, and --env overrides it [self-host]"`
- [x] `test "parallel mk builds 7c repeatedly without hanging [self-host]"`
- [x] `test "/proc/n/segment lists Stack first [self-host]"`
- [x] `test "/proc/n/regs and fpregs read a stopped process's registers [self-host]"`
- [x] `test "/proc/n/mem reads a variable and a write to text doesn't reach a sibling [self-host]"`
- [x] `test "/proc/n/mem writes to text are fetched by the next run, including a rewrite of the same address [self-host]"`
- [x] `test "ctl hang stops a process at exec, and start runs it [self-host]"`
- [x] `test "ctl stop stops a process spinning in guest code [self-host]"`
- [x] `test "a BRK posts sys: breakpoint [self-host]"`
- [x] `test "acid attaches and prints registers and a stack trace [self-host]"`

`tests/backends.zig` gains `test "BRK exits as a breakpoint on every backend [self-host]"`, using a hand-assembled fixture.

Already done and untagged, as bug fixes: `test "concurrent processes contending for one environment don't hang"` and `packArgs`'s unit test.

## Implementation

1. **Already in this draft's commit:** the `setArgs` fix, `-DPTHREAD`, and their tests.
2. `NPROC` in the default guest environment, with its case. README: how to build with source, and the writable-copy recipe.
3. `H9_TEST_SRC` and `-Dsrc` in `build.zig`, and the build cases (cwd, stock mkfile, library, read-only install, parallel mk). These pass today, so they land with the plumbing.
4. `vmm.Exit.breakpoint` in hvf and emu, `sys: breakpoint` in the machine loop, and the backend and integration cases.
5. devproc `text` (read-only, no stopping needed), and the `Stack`-first check on `segment`, which [segattach](segattach.md) serves.
6. Stop points and the record's saved Ureg and Extra, then `ctl` `stop`, `start`, `waitstop`, `startstop`, and `hang`, and the `Stopped` and `Stopwait` states.
7. `AddressSpace.codeChanged` in hvf and emu, then devproc `regs`, `fpregs`, and `mem`, including copy-on-write text.
8. The acid case and demo. SPEC.md: devproc's row, the Debugging section, and the process model table. Then `status: implemented`.

## Open issues

- **Code-cache invalidation cost on emu.** Unicorn's whole-cache flush is the simple way to drop stale translated blocks after a text write. If stepping through hot code makes that too slow, emu could flush only the blocks for the written range (`uc_ctl_remove_cache`). Measure it with the acid case before choosing.

## Updates

- 2026-11-07: Implemented. Details settled during implementation:
  - **Stop points.** A process stops at syscall entry, at note delivery (which `stop`'s kick forces for a process spinning in guest code), on a breakpoint exit, and after `exec` with `hang`. Syscall return isn't a separate point: the next one is the following syscall entry or kick, which acid can't tell apart.
  - **`fpregs`** reads only while the process is stopped, since a running process's FP state lives in its vCPU. On 386 it's the 512-byte FXSAVE image, as on amd64.
  - **Errors.** Missing register state fails with drawterm's `Enoreg` string rather than 9front's "no register set"; acid only checks that the read fails.
  - **Self-stop.** A process may write `stop` to its own `ctl` while a debugger waits on it with `waitstop`. 9front refuses that with `Einuse`; the integration fixture stops itself at known points this way, and acid never does it.
  - **The read-only install case** runs under `--write=scope`. Since [overlay](overlay.md) became the default, `mk install` succeeds into the run's overlay and is discarded; `--write=scope` gives the read-only root the case means.
  - **KVM** ([kvm](kvm.md)) landed first, so it gets the breakpoint exit too: EC 0x3C/0x30/0x31 on arm64, and on amd64 vector 3, whose IDT gate is now DPL 3 so a user-mode `INT3` reaches it instead of raising `#GP`. `codeChanged` bumps the same flush epoch as on hvf.
  - **Code caches on emu.** Unicorn's whole-cache flush is used. acid's `step` and `next` over `sleep`'s `main` stayed interactive on the emulator, so the per-range flush wasn't needed.
- 2026-11-07: `scripts/mkroot.py` is now a Zig tool, `tools/mkroot.zig`, run as `zig build mkroot -- --src`. The options and the tree it builds are unchanged.
