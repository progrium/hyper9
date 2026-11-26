# The 9front ABI

This describes, as built, what a 9front binary sees: the binary ABI on each architecture, how an a.out is loaded, the system calls, and what Go's `GOOS=plan9` programs need. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Binary ABI](#binary-abi)
- [a.out loading (host side)](#aout-loading-host-side)
- [Syscall table](#syscall-table)
- [Go programs](#go-programs)

## Binary ABI

The values below are checked against 9front source. They come from `sys/src/9/{arm64,pc64}/mem.h` and `trap.c`, plus `sysexec` in `port/sysproc.c`.

| Item | arm64 (`R_MAGIC`) | amd64 (`S_MAGIC`) | 386 (`I_MAGIC`) |
| --- | --- | --- | --- |
| UTZERO (text start) | 0x10000 | 0x200000 | 0x1000 |
| USTKTOP (stack top) | 0x7FFFF0000 (36-bit user addresses) | 0x7FFFFFFFF000 | 0xDFFFF000 |
| Stack size | 16 MiB | 16 MiB | 16 MiB |
| Page size | 4 KiB | 4 KiB | 4 KiB |
| Data segment alignment | 64 KiB | 2 MiB | 4 KiB |
| Syscall number | R0 | BP (RARG) | AX, with `INT $64` |
| Syscall arguments | user stack, from SP+8 | user stack, from SP+8 | user stack, from SP+4, in 4-byte words; a `vlong` takes two |
| Syscall result | R0 | AX | AX |
| Registers after a syscall | R1 to R17 zeroed (9front's `forkret` leaves the kernel's values there); the rest kept | BX, DX, SI, DI, R8 to R10, R12, R13, and BP zeroed, as `forkret` does; CX and R11 hold the PC and flags (`SYSRET`); R14 and R15 kept | all kept (`forkret` reloads the Ureg) |
| Registers at entry | R0 = Tos pointer; SP points at argc, argv follows | AX = Tos pointer; SP points at argc; R14 and R15 zeroed | AX = Tos pointer; SP points at argc |
| Note handler entry | R0 = Ureg pointer; SP+8 = Ureg, SP+16 = message | BP = Ureg pointer; same stack layout | no register; SP+4 = Ureg, SP+8 = message, in 4-byte words |

The registers after a syscall apply to every return through the normal path, including `rfork`'s in the child and a failed `exec` or `noted`; a successful `exec` starts with the entry registers, and `noted` restores the handler's Ureg. A program that keeps a value in a zeroed register across a call fails in h9 as it would on 9front. The Linux ABI keeps Linux's rules.

Pointers, argv, the words of the note frame, and the Tos's pointers follow the architecture's word size, so 386's Tos is 56 bytes with `pid` at 48. `noted` on 386 keeps the segment selectors and the flags outside 0xCD5 (IF, IOPL, TF) from the kernel's copy, as 9front's `setregisters` does.

## a.out loading (host side)

1. Read the Exec header: eight big-endian 32-bit words. Both 64-bit magics set HDR\_MAGIC, so a big-endian 64-bit entry address follows, making the header 40 bytes; 386's has none, so its entry is the header's 32-bit `entry` word and the header is 32 bytes.
2. Map file bytes \[0, header + text) read-only at UTZERO, filled from the file on first touch. The header is part of the text segment, and the entry point must fall inside it.
3. Map the next `data` bytes of the file at the end of text, rounded up to the data alignment, also filled on first touch and copy-on-write. bss starts at the end of data rounded up to 4 KiB, and is zero-filled.
4. The stack is \[USTKTOP − 16 MiB, USTKTOP), mapped whole, with pages allocated on first touch ([memory-model](../design/memory-model.md)). A zeroed Tos sits at the very top. Below it go the argument strings, then the argv array, then argc at SP.
5. Tos fields: the host fills `pid` and `cyclefreq` and keeps `kcycles`/`pcycles` current; the profiling pointers stay zero.

## Syscall table

9front's `libc/9syscall/sys.h` defines numbers 0–53; 48 and 49 are unused. The underscore entries (`_READ`, `_WRITE`, `_STAT`, `_NSEC`, and so on) are old compatibility calls that current libc doesn't use.

h9 implements only the current calls, plus `_NSEC` (53), which Go's `syscall.Gettimeofday` uses ([go-compat](../design/epoch-0/go-compat.md)): as 9front's `sys_nsec`, it returns the wall time in nanoseconds in the return register on 64-bit machines, and on 386 stores it through its argument and returns 0. The others post "sys: bad sys call", as the real kernel does for unknown calls.

`mount`, `unmount`, and `fauth` are served by drawterm's `sysmount` and `sysunmount` and a `fauth` wrapper over devmnt's `mntauth` (`h9_fauth` in `src/kern/glue.c`), so a guest mounts any 9P server it has an fd for: a posted channel, a pipe it serves itself, or a network connection the policy allowed. `mount` blocks until the server answers `Tversion` and `Tattach`, and a note interrupts it as it does any devmnt RPC.

Time otherwise comes from `/dev/bintime`, which h9's devcons hooks serve in nanoseconds with all four of 9front's words (see Kernel, "Added by us").

## Go programs

Go's `GOOS=plan9 GOARCH=amd64` binaries run unchanged ([go-compat](../design/epoch-0/go-compat.md)). Go has no `plan9/arm64` port and HVF runs arm64 only, so on an arm64 Mac they run on the emulator, on hx64. On Linux x86\_64 they run natively, on KVM or the sud engine, and on the emulator elsewhere. What the runtime and standard library need is served:

- **Startup:** `/dev/sysstat` has a line per CPU, so `runtime.NumCPU` and the default `GOMAXPROCS` follow `--cpus` (or the host's count); `#c/pid` gives the pid; `/dev/bintime` is opened as fd 18 for the clock. `/dev/swap` isn't served, and the runtime's 4 KiB fallback is right.
- **Threads:** each M is a process from `rfork(RFPROC|RFMEM|RFNOWAIT)`, and parks and wakes with `tsemacquire`, `semacquire`, and `semrelease` ([semaphores](../design/epoch-0/semaphores.md)).
- **Time:** `nanotime` uses `bintime`'s fourth word, the monotonic clock, and `walltime` its first; `syscall.Gettimeofday` uses `_NSEC`.
- **Processes and notes:** `os/exec` forks with `RFPROC|RFFDG|RFREND`, lists fds in `#d`, writes `/env`, execs, and waits with `await`; `os.Getppid` reads `#c/ppid`; `Process.Kill` and `Signal` write `/proc/n/note`. Fault notes carry `addr=`, so a nil dereference becomes a panic, and `interrupt` reaches `os/signal`.
- **Exit:** `os.Exit(n)` writes `n` as its `exits` string, which the CLI maps to exit code `n`.
- **Executable and mounts:** `os.Executable` reads `/proc/n/text` ([self-host](../design/epoch-0/self-host.md)), and the `mount` syscall is served (see Syscall table). Execs of 9front commands need `/amd64/bin` in the root, which `zig build mkroot` builds on an x86\_64 host ([i386](../design/epoch-0/i386.md)).
- **Memory:** rfork shares the parent's pages copy-on-write ([memory-model](../design/memory-model.md)), so a program that runs `os/exec` many times fits in a `--memory` of 512 MB.

The go-compat integration cases (tagged `[7]`) run the programs in `tests/fixtures/go` on the sud engine where the build has it (Linux x86\_64), and on the emulator elsewhere, and `zig build go-stdtest` runs Go's own `time`, `syscall`, `os`, and `runtime` tests to find gaps.
