---
slug: go-compat
title: Go compatibility
status: draft
created: 2026-11-03
authors: [progrium]
depends: [semaphores]
areas: [kern]
---

# Proposal: Go compatibility

## Abstract

Run Go's `GOOS=plan9 GOARCH=amd64` binaries. h9 serves `/dev/bintime` with nanosecond and monotonic time from its console device, replacing drawterm's whole-second version, and implements `_NSEC` as 9front does. With semaphores, that's everything Go's runtime needs.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is DESIGN.md's Go compatibility section as it stood there, with milestone references replaced by what's built and what's proposed. Rationale, Compatibility, Security and Implementation are to be written before filing.

Go has ports for `plan9/386`, `plan9/amd64` and `plan9/arm`, but not `plan9/arm64`, so on arm64 hosts Go binaries run as amd64 under the emulator (`--backend emu`) until someone ports Go to plan9/arm64. These notes are from Go 1.25's `runtime/os_plan9.go`, `runtime/sys_plan9_amd64.s` and `syscall/syscall_plan9.go`.

**What the runtime needs**

| Need | Used for | Status |
| --- | --- | --- |
| AX holds the Tos pointer at entry | `_rt0_amd64_plan9` saves it in `_tos`; g lives in `_privates` on the stack, not in FS, so there's no TLS setup | Built |
| `open`, `pread`, `pwrite`, `seek`, `close`, `dup`, `errstr`, `exits`, `brk_`, `sleep` | Basic I/O, the heap, `osyield` | Built |
| `rfork(RFPROC\|RFMEM\|RFNOWAIT)` | One Plan 9 process per M (OS thread) | Built |
| `notify` / `noted`, `/proc/n/note` | `sigtramp` turns notes into panics; the runtime posts notes to its own Ms | Built |
| `semacquire`, `tsemacquire`, `semrelease` | `semasleep`/`semawakeup`, so every lock and park | [semaphores](semaphores.md) |
| `/dev/bintime`, 4 words, nanoseconds | `nanotime` and `walltime` (below) | This proposal |
| `_NSEC` (53) | `syscall.Gettimeofday` only; the runtime doesn't use it | This proposal |
| `/env`, `/dev/random` | `os.Getenv`, `crypto/rand` | Built; `/dev/random` comes from drawterm's devcons |
| `/dev/sysstat`, `/dev/swap` | CPU count and page size; the runtime falls back to 1 CPU and 4 KiB if they're missing | Optional |

**Time.** The runtime opens `/dev/bintime` at startup, moves it to fd 18, and `pread`s it for every clock read. It asks for four big-endian 64-bit words: nanoseconds since the epoch, ticks, tick frequency and monotonic nanoseconds. If the read returns only three, it uses the wall-clock word as the monotonic clock. drawterm's `readbintime` in `kern/devcons.c` has two problems: it computes the time as `seconds()*1000000000`, so the clock only moves once a second, and it returns at most three words. Under it, Go's timers, `time.Sleep`, timeouts and the scheduler's clock would all be off by up to a second, and the monotonic clock would follow host wall-clock changes. 9front's libc `nsec()` reads the same file, so native programs see whole seconds too. The fix is to serve `bintime` from our console device (`src/kern/devhcons.c`), bound over `/dev` like `cons`, with 9front's four-word layout: wall time in nanoseconds, ticks and frequency from the host's monotonic clock, and monotonic nanoseconds. The vendored tree stays unmodified.

**`_NSEC`.** 9front still implements `_NSEC` for binary compatibility (`sys_nsec` in `port/sysproc.c`), returning the time in the return register on 64-bit machines. Go's `syscall.nsec` reads the return value and only falls back to the pointer argument if it's 0. h9 implements it the same way, from the same clock as `bintime`. The other underscore calls stay unimplemented.

## Done when

- A Go program built with `GOOS=plan9 GOARCH=amd64` that starts goroutines, sleeps for 100 ms and prints the elapsed time runs under `h9 --backend emu`, and the elapsed time it prints is at least 100 ms and under 200 ms.
