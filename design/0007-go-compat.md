---
id: 7
slug: go-compat
title: Go compatibility
status: implemented
created: 2026-11-03
authors: [progrium]
depends: [3]
areas: [kern, tests]
---

# Proposal: Go compatibility

Nov 5, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Run Go's `GOOS=plan9 GOARCH=amd64` binaries. Semaphores, from [semaphores](0003-semaphores.md), are the large missing piece. Four smaller ones are here:

- `/dev/bintime` and `/dev/time` with nanosecond wall time and a monotonic clock, instead of drawterm's whole seconds
- `#c/pid` and `#c/ppid`, which Go reads by device path and drawterm doesn't serve
- `/dev/sysstat`, with a line per vCPU the machine may run, so `runtime.NumCPU` isn't 1
- `_NSEC`, as 9front serves it

All of it is in drawterm's devcons, through small hooks into h9's own code, except `_NSEC`, which is a syscall. Go programs then start, schedule goroutines on several processes, keep time, and exec, the same on every backend that runs amd64.

The CLI also maps an `exits` string that's a plain decimal number from 1 to 255 to that exit code, so `os.Exit(n)` exits with `n`, for every program.

## Background

This was part of milestone M5 ("servers") in SPEC.md, before milestones became proposals ([#1](0001-proposals.md)). SPEC.md's Go compatibility section, which moved here, was written from Go 1.25. This proposal is checked against Go 1.27.3, the current release, and its `runtime/os_plan9.go`, `runtime/sys_plan9_amd64.s`, `syscall/syscall_plan9.go`, `syscall/exec_plan9.go`, `os/sys_plan9.go`, and `os/exec_plan9.go`.

Go has ports for `plan9/386`, `plan9/amd64`, and `plan9/arm`, but not `plan9/arm64`. HVF runs arm64 only, so a Go binary on an arm64 Mac runs as amd64 on the emulator (`--backend emu`, Unicorn). On Linux x86\_64 it runs on the emulator too, until [kvm](0016-kvm.md) gives it hardware.

### What the runtime does

- **Entry.** `_rt0_amd64_plan9` saves AX, the Tos pointer, in `_tos`, and points `_privates` at its own stack frame. The goroutine pointer `g` lives there, not in FS, so there's no TLS setup. Each process has its own stack, so each has its own `g`.
- **`osinit`:**
  - reads `/dev/swap` for the page size, falling back to 4 KiB without it;
  - counts the lines of `/dev/sysstat` for the CPU count, falling back to 1;
  - gets the pid by reading `#c/pid`;
  - opens `/dev/bintime`, moves it to fd 18, and fails fatally if it can't.
- **Ms.** Each M (OS thread) is a Plan 9 process from `rfork(RFPROC|RFMEM|RFNOWAIT)`. `tstart_plan9` reads the new process's pid from `_tos->pid` and lays out a 64 KiB scheduler stack on the process's stack.
- **Locks and parking.**
  - `semasleep` and `semawakeup` are `tsemacquire` (or `semacquire` when there's no timeout) and `semrelease` on a word in the M.
  - `osyield` is `sleep(0)`, and `usleep` rounds up to `sleep(1)`.
- **Time.** `nanotime` and `walltime` `pread` fd 18 at offset 0. `nanotime` asks for four big-endian 64-bit words and uses the fourth, the monotonic clock, if it gets all four. Otherwise it uses the first, wall time in nanoseconds. `walltime` uses the first.
- **Notes.**
  - `sigtramp` turns notes into signals. The fault notes `sys: trap: fault read` and `sys: trap: fault write` become panics, using the `addr=` in the note, and `interrupt` and `hangup` reach `os/signal`.
  - On exit, `goexitsall` writes "go: exit …" to `/proc/n/note` of every other M, then calls `exits`.
- **Memory** comes from `brk_`, as for C programs.

Go doesn't preempt goroutines by signals on Plan 9 (`preemptMSupported = false`), so nothing here needs asynchronous notes into a running M.

### What the standard library does

- **`syscall`:** `Getpid` and `Getppid` read `#c/pid` and `#c/ppid`. `Gettimeofday` uses `_NSEC` (53) and takes the time from the return register, or from the pointer argument when the register is 0.
- **`os.Hostname`** reads `#c/sysname`.
- **`os/exec`** (`syscall.forkExec`):
  - forks with `RFPROC|RFFDG|RFREND`, plus `RFCENVG` for a custom environment;
  - lists open fds by reading `#d` and closes the ones it doesn't pass;
  - writes the environment into `/env`;
  - execs, and reports a failed exec through a pipe;
  - waits with `await`.
- **`os.Process.Kill` and `Signal`** write `/proc/n/note`.
- **`os.Executable`** reads `/proc/n/text`.
- **`os.Getenv`** reads `/env`, and the `time` package's local zone comes from `$timezone`.
- **`net`** dials through `/net/cs` and `/net/tcp`.

### h9 today

Everything above is served except the following:

| Need | Today | |
| --- | --- | --- |
| `semacquire`, `tsemacquire`, `semrelease` | "sys: bad sys call" | [semaphores](0003-semaphores.md) |
| `/dev/bintime` | drawterm's `readbintime`: `seconds()*1000000000`, so the clock moves once a second, and at most three words | Here |
| `/dev/time` | drawterm's `readtime`, from `seconds()` too | Here |
| `#c/pid`, `#c/ppid` | Not in drawterm's devcons, so the open fails. The runtime then parses an empty read as pid 0 for the main M, and `syscall.Getpid` fails. | Here |
| `/dev/sysstat` | Empty, so `runtime.NumCPU()` is 1 and `GOMAXPROCS` defaults to 1 | Here |
| `_NSEC` | "sys: bad sys call" | Here |
| `/proc/n/text` | Not served | [self-host](0010-self-host.md) |
| `/dev/swap` | Not served; the runtime's fallback is right for h9 | Not planned; see Rationale |
| `os.Exit(n)` | `exits("n")`, so h9 exits 1 and prints "n" | Here |

Two details checked along the way:

- **Byte order.** drawterm's `readbintime` encodes with a function named `vlong2le`, but it's 9front's `vlong2be` under another name, with the same order constant and loop. The bytes are big-endian, as Go and 9front's `nsec()` expect. Only the resolution and the missing fourth word are wrong.
- **Fault notes.** h9's text is "sys: trap: fault read addr=0x… pc=0x…", and Go's `sigpanic` finds `addr=` in it, so nil-pointer dereferences already become panics once the rest works.

9front's own libc reads the pid from `_tos->pid` and the clock from `/dev/bintime` by path, so native programs never needed `#c/pid`. They do get whole-second `nsec()` today.

## Proposal

### The clock

h9 keeps one clock per host process, read through a Zig leaf. It has two parts, both nanoseconds:

- **Wall time** from the host's real-time clock (`std.Io.Clock.real`).
- **Monotonic time** from the host's monotonic clock, offset so it starts at the wall time when the kernel boots. Its values then look like wall time to a program that prints them, but never jump with the host's clock.

`ticks` are the monotonic nanoseconds, and `fasthz` is 1 000 000 000. `Tos.cyclefreq` keeps its current value, since nothing here reads it.

### devcons hooks

drawterm's devcons is vendored. Go reads `#c/pid` by device path, so serving it from h9's own console device, `#y`, which is bound over `/dev`, wouldn't reach it. So devcons gains leaf hooks, as devfs and devip carry h9's sandbox hooks. The leaves are in `src/kern/consx.c` and `src/kern.zig`; `third_party/drawterm/kern/devcons.c` gains:

1. Two `Dirtab` entries, `pid` and `ppid`, mode 0444. Their reads return `h9_cons_pid()` and `h9_cons_ppid()` as 9front formats them: right-justified in `NUMSIZE` (12) characters, plus a space. The pids are the machine-local ones from h9's process record, the same as `$pid`, `_tos->pid`, and `/proc`.
2. `readbintime` returns `h9_cons_bintime(buf, n)`: up to four big-endian words, as 9front's does. The words are wall nanoseconds, ticks, `fasthz`, and monotonic nanoseconds, and a short read gets the leading words that fit.
3. `readtime` returns `h9_cons_time(…)`: seconds, nanoseconds, ticks, and `fasthz`, in 9front's text format.
4. `Qsysstat`'s read returns `h9_cons_sysstat(…)`: one line per CPU the machine may use, in 9front's column layout. Each line has its index and zeros for the counters h9 doesn't keep (context switches, interrupts, syscalls, faults, TLB, and load). The count is `--cpus` when given, else the host's CPU count, capped by the backend's vCPU limit.

Writes are unchanged: drawterm refuses writes to `time` and `bintime` with "Egreg", and `sysstat` writes are a no-op.

Each hook is a one-line call. The leaves can't fail and raise no kernel errors (seam rule 3). With the hooks, `#c` and `/dev`, which `#y` shadows only for `cons`, `consctl`, and `stderr`, give the same answers.

### `_NSEC`

Syscall 53 returns the wall nanoseconds in the return register, as 9front's `sys_nsec` does on 64-bit machines, and writes nothing through its argument. It's the only underscore call h9 serves: the others keep posting "sys: bad sys call". `--trace` prints it as `_nsec`.

### Numeric exit statuses

Go's `os.Exit(n)` calls `exits` with `n` in decimal, and `exits("")` for 0. The CLI maps a numeric `exits` string to that number:

| `exits` string | Exit code | Printed to stderr |
| --- | --- | --- |
| empty | 0 | No |
| a decimal number from 1 to 255: digits only, no sign, no leading zero, no spaces | That number | No |
| anything else, including `"0"` | 1 | Yes |

The rule applies to every program, not just Go binaries, and lives in `src/cli.zig`, where a run's result becomes an exit code. `Machine` still returns the `exits` string unchanged, so library callers see what the program wrote.

A guest can now exit 2, 125, 126, or 127, the codes h9 uses for its own failures, as with `env` or `docker run`. h9 prints a message to stderr whenever it fails itself, and a numeric exit prints nothing, so the two can be told apart.

### Fixtures and the Go toolchain

The tests need Go binaries.

- **Sources:** `tests/fixtures/go/` holds a Go module with a small program per behaviour.
- **Building them:** `zig build go-fixtures` builds them with `GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0` and `GOTOOLCHAIN=go$GO_VERSION`. `GO_VERSION` is pinned in `scripts/pins.sh`, initially 1.27.3. Any installed Go fetches that exact toolchain, so every host builds the same binaries.
- **Without Go:** if `go` isn't on `PATH`, the step is skipped and the Go cases skip, as cases without a root tree do.
- **Runner:** the cases run on the emulator, `H9_TEST_BACKENDS=emu`, with `-Demu=unicorn`.
- **No 9front commands:** the root tree has no `/amd64/bin` yet (see Open issues), so no fixture execs 9front commands. The `os/exec` case re-execs the fixture itself.

### Go's standard library tests

`zig build go-stdtest` builds the test binaries for `time`, `syscall`, `os`, and `runtime`. It uses `go test -c` on the host, with the same toolchain and environment as the fixtures. It runs each one on the emulator with `--cwd` set to its package directory in the toolchain's `GOROOT`, so `testdata` is reachable through `/mnt/term/cwd`, and reports pass, skip, and fail counts for each package. These tests don't need a Go source tree or an amd64 root in the guest. Tests that exec `go` or 9front commands can't pass yet, so the step skips them with `-test.skip`, using a list kept next to the step.

The step is run by hand or on a schedule. It isn't part of `zig build test`, and it isn't one of the Done when cases: its job is to find gaps the fixtures miss.

## Rationale

**Hooks in devcons, not a shadow file in `#y`.**
- **The old plan:** SPEC.md planned to serve `bintime` from h9's console device, bound over `/dev` before `#c`, keeping the vendored tree unmodified. That works for `/dev/bintime`.
- **Why it isn't enough:** Go reads `#c/pid`, `#c/ppid`, and `#c/sysname` by device path, which no bind can change. So devcons has to change for `pid` and `ppid` anyway.
- **Why the clocks go there too:** putting them in devcons through the same hooks means `#c/bintime` and `/dev/bintime` can't disagree.
- **The cost:** the change is four call sites and two table entries, which `scripts/vendor-drawterm.sh` carries across upstream merges like the devfs and devip hooks.

**A wrapper device in h9's devtab.** h9's own `devtab.c` could register a `#c` that serves the new files and delegates the rest to drawterm's. It would have to merge directory listings and route by drawterm's private qid numbers, which is more code than the hooks and breaks quietly when upstream renumbers.

**Monotonic time offset to the boot's wall time.** Go uses the monotonic word only for differences, so any base works. Starting it at the wall time keeps 9front programs that print `ticks` or the fourth word plausible, as on 9front, where the monotonic clock starts near the time of day at boot.

**`sysstat` lines for CPUs, not real counters.** Go only counts the lines, and 9front's `stats` and `cpu` tools are the only other readers. Counting real context switches and syscalls per vCPU would need accounting h9 doesn't have. Zeros keep the format valid without pretending.

**Numeric exit statuses for every program.**
- **Why not only for Go:** limiting the mapping to Go binaries would mean detecting them, which is fragile and has no principled test.
- **Native programs:** 9front programs seldom exit with a bare number. Those that do, such as ported Unix tools, mean what Go means by it.
- **Not printing:** the code already carries the status, and Go programs print their own messages before `os.Exit`. Printing "3" as well would be noise that Go users don't expect.
- **Why `"0"` is still a failure:** a program that wrote a non-empty status meant failure. Mapping `"0"` to success would hide that.
- **The CLI, not `Machine`:** exit codes are a host-process idea. Library callers get the string and decide for themselves.

**Why not `/dev/swap`.** The runtime falls back to 4 KiB pages without it, which is right on amd64. If h9 served it, Go would trust its `pagesize` line for its allocator, so a wrong value there is worse than a missing file. 9front's `memory` and `stats` are the only other readers, and they only display it. It fits better in a later proposal that adds real per-machine accounting, together with real `sysstat` counters.

**Go's tests built on the host.** Running `go test` inside the guest would need the Go source tree there and an amd64 root to build it, which h9 doesn't have. Test binaries built with `go test -c` need neither, so the gaps they find show up now. They aren't a gate, because the result depends on which tests Go's tree has at the pinned version and which ones the step skips.

**Why not `/proc/n/text` here.** `os.Executable` needs it, but it's part of devproc's debugging files, which [self-host](0010-self-host.md) adds for acid. Go programs rarely call it, and it fails cleanly with an error when it's missing.

**Go on arm64 hosts.** SPEC.md treats cross-architecture emulation as testing-only. So on an arm64 Mac, Go `plan9/amd64` binaries run, but slowly and through Unicorn, which isn't in the MIT build. Two other proposals change that:
- [linux-personality](0018-linux-personality.md) runs `linux/arm64` Go binaries natively on HVF.
- Someone porting Go to `plan9/arm64` would make this proposal's work apply natively.

Neither is a dependency. And [i386](0009-i386.md) would let `plan9/386` binaries run as well.

## Compatibility

- **Native programs:** `nsec()` and `time()` gain nanosecond resolution, and `/dev/bintime` gains its fourth word. Programs that timed intervals in whole seconds see the right durations. Reads of `/dev/time` keep their format.
- **`#c/pid` and `#c/ppid`:** new files, so `ls '#c'` lists two more entries.
- **`/dev/sysstat`:** now has content. `runtime.NumCPU()` in Go, and any 9front tool that counts CPUs, see the machine's limit rather than 1.
- **`_NSEC`:** stops posting "sys: bad sys call".
- **Exit codes:** a program that exits with a decimal number from 1 to 255 now gives that code instead of 1, and the number is no longer printed. Scripts that check for exactly 1 see a different code, and ones that capture stderr no longer get the number. All other `exits` strings behave as before.
- **CLI flags, `Machine.Options`, `Machine`'s result, the vmm interface, and sandbox defaults:** unchanged.
- **Vendored tree:** devcons gains the hooks above.
- **Build:** a `go-fixtures` step, which `zig build test` depends on when `go` is available, and a `go-stdtest` step, which nothing depends on.

## Security

- **The pid files** expose the machine-local pids, which a guest can already see in `/proc`. They reveal nothing about the host's processes, or other machines in the same host process.
- **`sysstat`** reveals the machine's CPU limit and, without `--cpus`, the host's CPU count, which `/dev/sysstat` reveals on 9front too. A profile that wants to hide the host's count can set `--cpus`.
- **The clock** is read-only to the guest, as before. drawterm's writes to `time` and `bintime` already fail, and the hooks keep it that way. Nanosecond time makes timing measurements finer inside the guest. That's what every OS gives its programs, and the boundary doesn't rely on coarse time.
- **`_NSEC`** writes nothing to guest memory, so it has no pointer to check.

## Done when

The cases are tagged `[go-compat]`, built from `tests/fixtures/go/`, and run on the emulator. They need [semaphores](0003-semaphores.md) implemented first.

- `test "a Go hello world prints and exits 0 [go-compat]"`
- `test "goroutines sleep 100 ms and the elapsed time is right [go-compat]"`: the program starts goroutines, sleeps 100 ms, and prints the elapsed time, which is at least 100 ms and under 200 ms. This is the demo SPEC.md's Go section promised.
- `test "time.Now has sub-second resolution and matches the host [go-compat]"`: two readings 10 ms apart differ by 10 ms or more, and the time is within a second of the host's.
- `test "runtime.NumCPU follows --cpus [go-compat]"`: it prints 2 under `--cpus 2`.
- `test "os.Getpid and os.Getppid match /proc [go-compat]"`: they print the same pids as `/proc/n/status` and `/proc/n/ppid`.
- `test "CPU-bound goroutines run on several processes [go-compat]"`: with `GOMAXPROCS=4` and `--cpus 4`, `/proc` shows at least four processes during the run, and it finishes. It also finishes with `--cpus 1`.
- `test "os/exec runs a child and gets its exit status [go-compat]"`: the fixture re-execs itself from `/mnt/term/cwd`, with an environment variable telling the child what to do.
- `test "a nil dereference becomes a panic that recover catches [go-compat]"`
- `test "os/signal receives interrupt on Ctrl-C [go-compat]"`, on a pty as the existing Ctrl-C cases are.
- `test "os.Exit(3) exits with status 3 [go-compat]"`: h9 exits 3 and prints nothing to stderr.
- `test "a numeric exits string becomes the exit code [go-compat]"`: an rc case, so it doesn't need Go. `exit 3` gives 3 with an empty stderr, while `exit 0`, `exit 256`, and `exit 03` give 1 and print the string.
- `test "net/http fetches from a listener the test opens [go-compat]"`
- `test "syscall.Gettimeofday has microsecond resolution [go-compat]"`, through `_NSEC`.
- `test "/dev/bintime has four words and a monotonic clock [go-compat]"`: an rc case reads 32 bytes from `/dev/bintime` twice, and the fourth word grows by at least the time slept between the reads.

## Implementation

1. The clock leaf and `_NSEC` in `src/syscall.zig`, with its trace.
2. `src/kern/consx.c` and the leaves in `src/kern.zig`, then the hooks in `third_party/drawterm/kern/devcons.c`. The `/dev/bintime` case passes.
3. The numeric exit statuses in `src/cli.zig`, and their rc case.
4. `tests/fixtures/go/`, `GO_VERSION` in `scripts/pins.sh`, and `zig build go-fixtures`.
5. With [semaphores](0003-semaphores.md) implemented, the Go cases, then `zig build go-stdtest` and its skip list.
6. The README: the exit codes paragraph, and the Go fixtures and `go-stdtest` steps.
7. SPEC.md:
   - the syscall table paragraph: `_NSEC` is served and `/dev/bintime` is nanosecond and monotonic
   - the kernel's "Added by us" table: the devcons hooks
   - the terminal paragraph's exit status sentence, and the CLI's exit code table
   - a short "Go programs" section on what runs and where
   
   Then set `status: implemented`.

## Open issues

- **An amd64 root tree.** A Go program that execs 9front commands needs `/amd64/bin`. `scripts/mkroot.py` builds an arm64 tree only, so on amd64 those execs fail with "file does not exist". This should be its own proposal. The likely approach is a post-step in `mkroot.py` that runs `objtype=amd64 mk install` inside h9 on the arm64 root, which [self-host](0010-self-host.md) shows working, rather than unpacking a second 9front image. That gives one root tree with both architectures, and it answers [i386](0009-i386.md)'s question about getting 386 binaries the same way. With it, Go fixtures can exec 9front commands, and `go-stdtest` can run more of its tests.
## Updates

**Nov 6, 2026.** Notes from the implementation:

- **The emulator serializes guest code.** Unicorn translates code for a single-threaded context, so guest atomics aren't atomic across engines, and Go's runtime crashed ("unlock of unlocked lock") as soon as two Ms ran at once. Each emu backend now runs guest code on one engine at a time, passing the turn at exits; kernel calls still run in parallel. Preempting on a timer was tried and dropped, because an engine stopped from another thread can resume at an earlier block and run instructions twice. See SPEC.md, "Emulator backend".
- **Memory.** Go reserves several hundred MB of `brk` at start. The emulator no longer zeroes new pages by hand, and rfork's copy skips zero pages, which took a Go hello world from about 3.5 s to 0.3 s. rfork still copies eagerly and the pages count against `--memory`, so the `os/exec` case runs with `--memory 4G`; copy-on-write rfork would remove the need.
- **`_NSEC` on 386** stores the time through its argument and returns 0, as 9front's `sys_nsec` does on 32-bit machines, instead of using only the return register.
- **`/dev/time`** keeps drawterm's four fields, as Compatibility says; 9front's current devcons prints a fifth, the monotonic time.
- **The Go cases don't need the root tree.** Each runs with a scratch root holding only the namespace's mount points, and the fixtures at `/mnt/term/cwd`, so they run wherever Go and the emulator are. The two rc cases still need the tree.
- **The `spin` fixture yields** with `runtime.Gosched` between rounds: Go doesn't preempt goroutines on Plan 9, so a loop with no calls would hold its P and starve `main` there too.
- **`go-stdtest` found** that the runtime's `TestPageAllocGrow` reserves more than `--memory` allows, so it's in the skip list; other failures are counted, not skipped. `syscall`'s `TestPlan9Syserr` needed the `mount` syscall, which [devsrv](0008-devsrv.md) now serves, and passes.
- **A note could miss a blocking call.** drawterm's call wrappers clear the "interrupt this call" flag when a call returns, so a note posted while one call was finishing was lost if the guest's next exit was a blocking call, such as Go's `semacquire` while `go: exit` notes go round; the program then hung about one run in four under load. The exit loop now interrupts a call it starts with a note flagged, and the note's kick is posted before its interrupt, so one of the two always reaches the call.
- **rc's `exit 0` exits 0.** rc counts a status of only `0` and `|` as true and calls `exits("")` for it, so the rc case checks that `exit 0` gives 0; `exits("0")` itself still gives 1, which `src/cli.zig`'s tests cover. `exit 256` and `exit 03` give 1 and print, as Done when says.
