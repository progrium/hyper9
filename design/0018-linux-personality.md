---
id: 18
slug: linux-personality
title: Linux personality
status: draft
created: 2026-11-04
authors: [progrium]
depends: [34, 33]
areas: [kern, vmm, cli, sandbox]
---

# Proposal: Linux personality

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 runs Linux ELF binaries next to 9front ones, in the same machine. A process's personality is chosen at exec by its binary format. A Linux process's syscalls are served by a second syscall table in the host, translated onto the same drawterm kernel. So Linux processes share the machine's mount table, file descriptors, pipes, notes, and sandbox policy with 9front processes, and the two can pipe to each other and exec each other. Each process has its own root: a Linux process's `/` is a Linux root tree, such as Alpine's minirootfs, with the 9front tree at `/9` when the machine has one. `--root` takes either kind of tree and h9 tells them apart, so there's no Linux-specific flag. This proposal covers single-threaded programs, static and dynamic. Threads ([linux-threads](0049-linux-threads.md)) and readiness with sockets ([linux-net](0050-linux-net.md)) are their own proposals, built on this one.

## Background

h9 already has the shape of a syscall-translating kernel. Each guest process runs in user mode on a vCPU, a syscall exits to the host, and a kernel in the host serves it (DESIGN.md, Architecture). gVisor has the same shape: its KVM platform is h9's vmm layer, and its Sentry is drawterm's kernel. What's missing is a second ABI.

Linux binaries trap with the same instructions as 9front's: `SVC` on arm64 and `SYSCALL` on amd64. So a Linux syscall already arrives as the vmm's `.syscall` exit, with every register the Linux ABI uses already in the Ureg:

- **arm64:** the number in x8, arguments in x0 to x5, the result in x0.
- **amd64:** the number in rax, arguments in rdi, rsi, rdx, r10, r8, and r9, the result in rax.

Today `syscall.dispatch` reads that exit as a 9front call: on arm64 it takes the number from R0, which for a Linux `write(1, …)` is the valid 9front call 1.

Other pieces already fit:

- **Address space.** HVF's guest page tables already use a 48-bit user address space (`TCR_EL1.T0SZ` = 16 in `src/vmm/hvf.zig`); only the guest-physical space is 36 bits. Linux's usual layout fits: ld.so mapped high, and the stack near the top of the 47-bit range. Large virtual reservations cost no guest-physical memory as long as their pages are allocated on first touch.
- **Thread pointer.** `vmm.Extra.tls` already carries the thread pointer across pooled vCPUs and into rfork children: TPIDR_EL0 on arm64, the FS base on amd64.
- **Per-process root.** drawterm resolves an absolute path from `up->slash` (`kern/chan.c`), and h9 already sets `slash` per process (`src/kern/proc.c`). Plan 9's mount table is keyed by channel, not by path, so two processes with different `slash` can share one Pgrp.
- **Guest memory access.** `src/guestmem.zig` already copies across region boundaries, so syscall buffers that span several mappings work.
- **Prior art.** linuxemu (Russ Cox, then cinap_lenrek) ran Linux/i386 ELF binaries on Plan 9 as an ordinary Plan 9 program. It caught Linux's `int 0x80` as a note, built mmap on segattach and segbrk, and ran Linux programs in a namespace with the Linux root bound over `/` and Plan 9's at `/9`. hyper-linux, already h9's reference for the HVF shim, has a working ELF loader and auxv setup.

What doesn't fit yet:

- **The vmm interface** maps and unmaps whole regions by their start address, and both backends search regions linearly. The emulator remaps every region into its engine, and flushes its translation cache, on any change. Linux programs make thousands of mappings and change parts of them with `munmap` and `mprotect`.
- **Exit statuses** are strings in Plan 9 and small integers in Linux, and the CLI exits 1 for any non-empty string.
- **The emulator's regions are expensive to change.** Unicorn rebuilds its memory map on every map, unmap, or protect, at a cost that grows with the number of regions. With 64 KiB chunks, about 840 regions cost 2.9 ms per protect that splits a region, and about 1,600 cost 28 ms. Mapping 2,048 regions takes 1.9 s. `pip --version` makes about 12,000 `mmap`/`munmap` pairs and 17,000 page faults, so it took 88 s on a prototype built this way.

A prototype of this proposal, in Python on Unicorn 2.1.4 (the version h9's emulator links), ran Alpine's busybox shell pipelines, `apk`, and CPython, static and dynamic, on arm64 and amd64, with about 110 calls and no vDSO. The findings it turned up are folded into the sections below.

## Proposal

### Personality and dispatch

Each process has a personality, `plan9` or `linux`, set by exec from the binary's magic: the a.out magics as today, or `\x7fELF`. On a `.syscall` exit, `Machine.loop` dispatches to `syscall.dispatch` or `linux.dispatch` by personality. Both return the existing `Outcome` union:

- `exits` for `exit` and `exit_group`
- `rfork` for `fork`, `vfork`, and `clone`
- `exec` for `execve`
- `noted` for `rt_sigreturn`, with a Linux frame (see Signals)

A Linux process can execve a 9front binary and the reverse. Each exec picks the personality anew, and sets the process's root to match (see The Linux view).

### The ELF loader

For a static or dynamic ELF64 executable of the host's architecture:

- Map the `PT_LOAD` segments with their permissions. For a dynamic one, load the `PT_INTERP` interpreter at a fixed high base. `PT_GNU_STACK` is honoured: the stack is never executable unless it asks.
- Build the Linux initial stack: argc, argv, envp, then the auxv with `AT_PHDR`, `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ` (4096), `AT_BASE`, `AT_ENTRY`, `AT_RANDOM`, `AT_HWCAP`, `AT_HWCAP2`, `AT_CLKTCK` (100), `AT_SECURE` (0), `AT_UID`, and friends, and `AT_EXECFN`.
- `AT_HWCAP` and `AT_HWCAP2` report what the guest can actually use, which differs between HVF and the emulator. The backend reports them (see vmm changes).
- Give a minimal vDSO (`AT_SYSINFO_EHDR`): one read-only, executable page with an ELF header, a dynamic symbol table, and a single symbol, `__kernel_rt_sigreturn` on arm64 (`mov x8, #139; svc #0`). It's the signal return address for handlers installed without `SA_RESTORER`, which Go's `linux/arm64` runtime relies on (see Signals). It exports no clock or `getrandom`, so musl, glibc, and Go still make real syscalls for those.
- Validate everything before tearing down the caller's image: the ELF header, the architecture, the interpreter, and every segment's bounds. A failed `execve` returns its error to the caller, as Linux's does; busybox's `PATH` search depends on that.
- A file starting with `#!` runs its interpreter, with the script's path as an argument, as Linux's `binfmt_script` does. Alpine ships shell-script tools.

Linux processes have no Tos.

### Syscalls

`src/linux/` holds the table, one entry per Linux syscall number per architecture. Calls map onto drawterm's `sys*` wrappers on the calling Proc, as `syscall.zig`'s do. Results are Linux's: a value, or `-errno`.

Arguments the ABI types as `int` (fds, flags, modes, `AT_FDCWD`) are narrowed to 32 bits on entry. On arm64 their upper halves aren't defined, and `AT_FDCWD` arrived sign-extended to 64 bits in the prototype, where busybox `tar` failed with `EBADF` until it was narrowed.

The table below names the calls by their arm64 (generic) names. musl on amd64 uses the older forms for many of them, so the amd64 table serves those too, onto the same code: `open`, `stat`, `lstat`, `access`, `readlink`, `dup2`, `pipe`, `rename`, `unlink`, `mkdir`, `rmdir`, `chmod`, `chown`, `link`, `symlink`, `getdents`, `select`, and `poll` (the last two from [linux-net](0050-linux-net.md)). In the prototype's runs on amd64, `stat`, `lstat`, `open`, and `readlink` were about 5,700 of the file calls.

Every entry is one of three kinds, so `-ENOSYS` always means "not known to h9":

- **Served:** translated onto the kernel, as in the table below.
- **Stubbed:** a fixed answer that's right for h9, listed in the table's last rows.
- **Absent:** `-ENOSYS`, and with `--debug` a line naming the call, so the gaps that matter can be found.

| Area | Calls | Served by |
| --- | --- | --- |
| Files | `openat`, `read`, `write`, `pread64`, `pwrite64`, `readv`, `writev`, `sendfile` (as a read and a write, for busybox `cat` and `tar`), `lseek`, `close`, `dup`, `dup3`, `fcntl`, `pipe2`, `getdents64`, `newfstatat`, `fstat`, `statx`, `faccessat`, `faccessat2`, `mkdirat`, `unlinkat`, `renameat`, `renameat2` (flags 0), `fchmod`, `fchmodat`, `fchownat`, `utimensat`, `ftruncate`, `truncate`, `fsync`, `fdatasync`, `getcwd`, `chdir`, `fchdir`, `readlinkat`, `statfs`, `fstatfs`, `close_range` (flags 0 and `CLOSE_RANGE_CLOEXEC`) | drawterm's file calls. A relative path with a dirfd is walked from the dirfd's Chan, through a `namec` variant in `src/kern/` that starts at a given Chan, not joined onto the dirfd's `fd2path` string: an fd inherited across a change of personality carries the other view's name, and a string join would resolve it in the wrong view. `stat` is built from a Plan 9 `Dir` (see Users and `stat`). `readlinkat` and `lstat`-style calls see links in trees resolved by [symlinks-in-root](0034-symlinks-in-root.md), and `EINVAL` elsewhere. `utimensat` and `fchownat` become a `wstat`. |
| Processes | `clone` (without `CLONE_VM`, or with `CLONE_VM` and `CLONE_VFORK`), `fork`, `vfork`, `execve`, `execveat`, `exit`, `exit_group`, `wait4`, `waitid`, `getpid`, `getppid`, `gettid`, `set_tid_address`, `kill`, `tgkill`, `tkill`, `setsid`, `setpgid`, `getpgid`, `getsid` | h9's process model (see Processes) |
| Memory | `brk`, `mmap`, `munmap`, `mprotect`, `madvise` (`DONTNEED` zeroes, the rest are hints), `mremap` | The VMA layer (see Memory) |
| Signals | `rt_sigaction`, `rt_sigprocmask`, `rt_sigreturn`, `rt_sigpending`, `rt_sigsuspend`, `rt_sigtimedwait`, `sigaltstack` | See Signals |
| Time | `clock_gettime`, `clock_getres`, `clock_nanosleep`, `nanosleep`, `gettimeofday`, `times` | The host clock, the same one [go-compat](0007-go-compat.md) uses for `/dev/bintime`. `CLOCK_PROCESS_CPUTIME_ID` and `CLOCK_THREAD_CPUTIME_ID` read 0 until there's per-thread CPU accounting, as `/proc/n/status` does. |
| Terminal | `ioctl` `TCGETS`, `TCSETS*`, `TIOCGWINSZ`, `TIOCGPGRP`, `TIOCSPGRP` on the console; `FIONREAD` | `TCSETS` with `ICANON` off writes `rawon` to `/dev/consctl`, and `rawoff` when it's on again. The termios is kept on the console. While it's raw with `ISIG` set, as busybox's line editing leaves it, the console turns its `VINTR`, `VQUIT`, and `VSUSP` bytes into `SIGINT`, `SIGQUIT`, and `SIGTSTP` for the foreground process group instead of input (see Signals). `isatty` and line editing work. Other ioctls are `-ENOTTY`. |
| Other | `uname`, `getrandom`, `sysinfo`, `getuid`, and the other id calls, `umask`, `prctl` (`PR_SET_NAME`, `PR_GET_NAME`, `PR_SET_PDEATHSIG`), `arch_prctl` (amd64 `ARCH_SET_FS`, `ARCH_GET_FS`) | Fixed answers, or the host where it's safe. `uname` is `Linux`, release `6.1.0-h9`, with the machine's architecture; the node name is `sysname`. |
| Stubbed | `prlimit64` and `getrlimit` (the machine's limits: `--memory` for `RLIMIT_AS`, 1024 files), `setrlimit` (accepted, ignored), `sched_getaffinity` (the `--cpus` count), `sched_yield`, `getpriority`/`setpriority`, `membarrier` (`-EINVAL` for every command but query), `rseq` (`-ENOSYS`, which glibc expects), `set_robust_list` (accepted; see [linux-threads](0049-linux-threads.md)), `chroot`, `mount`, `umount2`, `pivot_root`, `unshare`, `setns`, and `clone` with any `CLONE_NEW*` flag (`-EPERM`; [dotl](0022-dotl.md) adds `mount -t 9p`), `linkat`, `symlinkat` (`-EPERM`), `flock` and `fcntl`'s `F_SETLK`, `F_SETLKW`, `F_GETLK`, and `F_OFD_*` (accepted, and no lock is taken; `F_GETLK` reports `F_UNLCK`), `fadvise64`, `mlock`, `munlock`, `mlockall`, `munlockall`, `sched_setaffinity` (accepted), `getxattr`, `lgetxattr`, `fgetxattr`, `listxattr`, `llistxattr`, `flistxattr`, `setxattr`, and the rest (`-ENOTSUP`), `personality` (`PER_LINUX` for a query, `-EINVAL` for any other persona), `ptrace` (`-EPERM`), `bpf`, `perf_event_open` (`-EPERM`), `seccomp` and `prctl(PR_SET_SECCOMP)` (`-EINVAL`, so no program believes a filter is enforced), `prctl(PR_SET_NO_NEW_PRIVS)` (success; it's already true), `io_uring_setup` (`-ENOSYS`; libuv and liburing fall back to ordinary calls) | |

Calls that need readiness (`poll`, `ppoll`, `pselect6`, `epoll_*`, `eventfd2`) and sockets come in [linux-net](0050-linux-net.md). `fcntl` accepts and records `O_NONBLOCK` here, but reads and writes block until that proposal is built. That leaves out more than servers: CPython's `subprocess` with `capture_output` or `communicate()` waits on its pipes with `poll` (`ppoll` on arm64), and Go's runtime opens an epoll fd and an eventfd at its first timer, so both need linux-net.

Error strings map to errno: "file does not exist" is `ENOENT`, "permission denied" is `EACCES`, "interrupted" is `EINTR`, "file already exists" is `EEXIST`, "not a directory" is `ENOTDIR`, "is a directory" is `EISDIR`, "write on closed pipe" is `EPIPE`, and unknown strings are `EIO`. The table lives in one place, shared with [dotl](0022-dotl.md) (see Rationale), and is tested on its own.

### Users and `stat`

`qid.path` becomes `st_ino`, and the device type and number become `st_dev`. Plan 9 modes become Linux modes, with `DMDIR` as `S_IFDIR` and the rest `S_IFREG`, except that devices under the Linux `/dev` report as character devices.

Inside the Linux root, the machine's user is uid 0 and gid 0, as in a rootless container. Package managers and many scripts refuse to run otherwise, and it grants nothing: every access is still decided by the namespace, devfs, and the policy, which don't look at Linux ids. A process can still become another user, as `su` and daemons that drop root do, and keeps its own ids from then on (2026-11-08 Updates). Other user and group names map to numbers through the Linux root's `/etc/passwd` and `/etc/group`, read when the machine starts, and any other name is 65534 (`nobody`). The reverse, for `fchownat`, is the same table; an unknown number is `-EPERM`.

### Processes

- **`fork`, and `clone` without `CLONE_VM`,** is `rfork` with `RFPROC|RFFDG` and the Linux address space copied (see Memory).
- **`vfork`, and `clone(CLONE_VM|CLONE_VFORK)`,** creates a child that shares the parent's address space, on the stack the caller gives, while the parent waits until the child execs or exits. musl uses this for `vfork` and `posix_spawn`, so busybox needs it. While the parent waits nothing else runs in the shared space, so it needs none of [linux-threads](0049-linux-threads.md)'s TLB shootdown.
- **`clone` with `CLONE_VM` and without `CLONE_VFORK`** is `-ENOSYS` until [linux-threads](0049-linux-threads.md).
- **`wait4` and `waitid`** map onto `await`, filtered by pid in h9 since `await` takes any child. Process groups (`setpgid`, `TIOCSPGRP`) are kept on the process for `wait4(-pgid)` and for job control's foreground group. The console's Ctrl-C and Ctrl-Z go to that foreground group while a Linux process has set one, and Ctrl-C goes to the note group otherwise (see Job control). `WUNTRACED` and `WCONTINUED` report stops and continues.
- **Exit statuses** map both ways. Linux `exit(0)` is `exits("")`, and `exit(n)` is `exits("n")` in decimal, as APE's `_exit` writes. A death by signal N is `exits("linux: signal N")`. For `wait4`, the reverse: `""` is status 0, a decimal string is that number modulo 256, `linux: signal N` is killed by signal N, a fault note is killed by `SIGSEGV`, and any other string is status 1.
- **The CLI** exits with a Linux program's status unchanged, through the numeric `exits` rule [go-compat](0007-go-compat.md) already built. A death by `linux: signal N` exits 128+N, through [exit-status](0033-exit-status.md).

### Memory

A Linux address space is a list of VMAs, kept sorted, alongside the existing segments.

- **Lazy pages.** Anonymous VMAs, the heap, and the stack get their pages on first touch: a `.fault` exit inside a VMA that allows the access allocates a page, maps it, and resumes, as the stack grows today. A fault outside any VMA, or against its permissions, is `SIGSEGV`. A `PROT_NONE` reservation, however large, costs no guest-physical memory. Pages are mapped in chunks of up to 64 KiB where the VMA allows, to keep the backend's region count down.
- **The host's own copies fault in too.** A `read` into a fresh heap page writes to memory that's inside a VMA but not mapped yet. `guestmem` pages it in before copying, and only a range outside every VMA, or against its permissions, is `EFAULT`.
- **`brk`** grows a heap VMA after the executable's last segment.
- **Private file mappings** are read through the kernel into fresh pages: eagerly for small files, or chunk by chunk on fault. `MAP_FIXED` replaces what's there, as musl's and glibc's loaders need.
- **Shared anonymous mappings** stay shared across `fork`, like segattach's `shared` segments. None of the prototype's runs (busybox, apk, CPython, pip, Go) made any `MAP_SHARED` mapping at all.
- **Shared writable mappings of files** are refused with `ENODEV`. drawterm has no page cache to write them back through, and h9 has nothing to keep two mappings of a file coherent. SQLite in WAL mode and LMDB are the common programs that need this. SQLite works with `PRAGMA locking_mode=EXCLUSIVE`, which keeps the WAL index in heap memory instead of a shared mapping of the `-shm` file. Serving them is left to a later proposal (see Open issues).
- **Read-only shared file mappings** are copies taken at `mmap`, like private ones. Linux programs expect such a mapping to see later writes to the file, and LMDB's default mode reads its database through one while writing with `pwrite`. So a read-only `MAP_SHARED` mapping through an fd opened for writing, as LMDB's is, is refused with `ENODEV` too: the program has said it will write the file, and a copy would go stale under it. A mapping through a read-only fd is served as a copy, and doesn't see writes made later by other processes or other 9P clients. Tracking those can't be done for files served by devmnt.
- **`fork`** copies the VMAs eagerly, as `rfork` copies segments. Copy-on-write is later performance work.
- **Limits.** Pages count against `--memory` when they're allocated, not when they're reserved, so a fault past the limit is `SIGSEGV` with a "virtual memory allocation failed" note under `--debug`. Virtual reservations are capped at the 47-bit user range.

### vmm changes

The `vmm` interface (`src/vmm.zig`) and both backends gain:

- **`AddressSpace.unmap(va, len)`** removes any page-aligned range, splitting regions as needed. Today's whole-region `unmap(va)` becomes a call with the region's length.
- **`AddressSpace.protect(va, len, perms)`** changes the permissions of any page-aligned range of mapped pages, splitting regions as needed.
- **Region lookup** in the HVF backend is a sorted structure with logarithmic lookup, not a linear scan.
- **The emulator keeps its own page table and runs Unicorn in virtual-TLB mode** (`UC_TLB_VIRTUAL` with a `UC_HOOK_TLB_FILL` hook), over one Unicorn region for all of the backend's guest-physical pages. A change to the address space is an edit to that page table and a TLB flush, not a change to Unicorn's memory map, and translated blocks are flushed only for ranges that lost execute permission or changed contents under it. A first touch inside a VMA can be served in the fill hook, without an exit. The page table has the shape of HVF's guest page tables, so both backends share the address-space code. In the prototype's benchmark, one change plus a pass over every chunk took 1.1 ms with 1,024 chunks and 2.0 ms with 2,048 (against 19 ms and 70 ms with one Unicorn region per chunk), and it grew linearly to 24 ms at 16,384, with a Python fill hook. [zig-interpreter](0019-zig-interpreter.md) needs the same: its software TLB fills from a page table, not a scan of regions.
- **`Backend.hwcaps()`** returns the guest-visible CPU features, for `AT_HWCAP`, `AT_HWCAP2`, and `/proc/cpuinfo`.

A change that removes or narrows access must take effect before the host reuses the pages. With this proposal at most one vCPU runs in a Linux address space at a time (a `vfork` parent waits), so the existing epoch flush at the next run is enough. [linux-threads](0049-linux-threads.md) adds the shootdown that concurrent threads need.

### Signals

Notes and signals map both ways:

| Note | Signal |
| --- | --- |
| `interrupt` | `SIGINT` |
| `hangup` | `SIGHUP` |
| `alarm` | `SIGALRM` |
| `sys: trap: fault …` | `SIGSEGV` |
| `sys: trap: illegal instruction …` | `SIGILL` |
| `sys: trap: divide error …` (amd64) | `SIGFPE` |
| `sys: write on closed pipe` | `SIGPIPE` |
| `kill` from `/proc/n/ctl` | `SIGKILL` |
| `linux: signal N` | Signal N |

Linux processes signal each other with `linux: signal N` notes, so a 9front process can also signal one by writing to `/proc/n/note`. A Linux process whose child exits gets `SIGCHLD`, synthesized by h9 when the wait record is queued, unless its `SIGCHLD` action is `SIG_IGN`. A note posted to a 9front process from a Linux one is the note's string for the known signals (`interrupt` for `SIGINT`) and `linux: signal N` otherwise, except that stop and continue signals aren't posted (see Job control).

`rt_sigaction` handlers, the signal mask, and the alternate stack are kept on the process. Delivery happens where notes are delivered today: at the top of the exit loop, and when a blocking call is interrupted, which returns `-EINTR` unless the handler has `SA_RESTART`. Delivery builds an `rt_sigframe` on the user stack, or the alternate stack, and enters the handler with the restorer as the return address: the handler's `sa_restorer` when it set `SA_RESTORER`, and otherwise the vDSO's `__kernel_rt_sigreturn`. musl sets `SA_RESTORER` itself; Go on arm64 doesn't (`_SA_RESTORER = 0` in its runtime), so without the vDSO every Go signal handler would return to address 0. The frame is laid out exactly as Linux's, since libc and debuggers read it:

- **arm64:** `siginfo`, then `ucontext` with the general registers in `sigcontext` and, in its `__reserved` area, an `fpsimd_context` record, an `esr_context` record for faults, and the terminating null record, with a frame record (`x29`, `x30`) above it. The prototype built this frame and returned through it, with FP state intact, for musl handlers and for Go's SIGURG preemption.
- **amd64:** `siginfo`, then `ucontext` with `sigcontext` and a pointer to an `fxsave`-format FP state.

Default actions follow Linux: terminate, ignore (`SIGCHLD`, `SIGURG`, `SIGWINCH`, and `SIGCONT` apart from continuing), or stop (`SIGSTOP`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU`).

**Job control.** A stop is real, not just reported: a shell that's told a job stopped prints its prompt and reads the console, and a job that kept running would compete with it for input.

- **Stopping.** A Linux process stops where signals are delivered, at the top of the exit loop. Its Proc sleeps on a `Rendez` in a new `Stopped` state that's kept on the Linux process record, not in drawterm's process model, so 9front processes and devproc's states don't change. A process blocked in a call when the signal arrives stops when the call returns. The call isn't interrupted, unlike a call that a caught signal interrupts. For a call blocked on input, such as ash's job reading the console, the stop takes effect at the next byte, which is a known gap. A vfork parent keeps waiting while its child is stopped.
- **Reporting.** The stop is queued for the parent's `wait4` and `waitid` with `WUNTRACED`, or `WSTOPPED`, and the parent gets `SIGCHLD` unless it set `SA_NOCLDSTOP`.
- **Continuing.** `SIGCONT` wakes the process, before any handler for it runs, and is reported with `WCONTINUED`. `SIGKILL` wakes a stopped process and kills it. Other signals stay pending until it continues. A note posted to a stopped process by a 9front one, such as `kill` through `/proc/n/note`, is pending in the same way, except `kill` through `/proc/n/ctl`, which is `SIGKILL`.
- **The console.** Ctrl-Z reaches a Linux process only from a raw console with `ISIG` set, which is how busybox's line editing leaves it: the console turns the `VSUSP` byte into `SIGTSTP` for the foreground process group (see Terminal). In cooked mode the host terminal's own Ctrl-Z suspends h9 itself, as today. `SIGTTIN` and `SIGTTOU` aren't generated: a background job's console read or write goes through. A machine's console has one foreground group, and the 9front side, which has no process groups, has no part in it.
- **9front processes** never stop. A `SIGSTOP` or `SIGTSTP` sent to one by a Linux process is dropped, as it would be for a process that ignores it.

`rt_sigreturn` restores the saved registers only after sanitizing them as `noted` does. On arm64 that means keeping only NZCV from the guest's PSR; on amd64, forcing the selectors and system flags. The HVF shim loads the PSR straight into `SPSR_EL1`, so this is the one place a forged frame could reach EL1.

### The Linux view

A Linux process's root is a small new device, `#λ` (devlinux, in `src/kern/`), not the machine's root. Its root directory holds `9`, `tmp`, and `mnt/term` as mount points, and serves `dev` and `proc` itself. When the machine starts, the namespace builder adds binds to the shared Pgrp:

```text
bind -a '#U/path/to/alpine' '#λ'       ro
bind / '#λ/9'
bind /tmp '#λ/tmp'
bind /mnt/term '#λ/mnt/term'
```

exec of an ELF sets the process's `slash` to `#λ`'s root, and exec of an a.out sets it back to the machine's root. `slash` is a reference-counted Chan that `rfork` shares (`src/kern/proc.c`), so replacing it at exec changes only the exec'ing process. The `#λ` attach has its path renamed to `/`, as `procinit.c` does for `#/`, so `fd2path` and `getcwd` give Linux paths in the Linux view with no translation. `walk` applies mounts to its starting Chan (`kern/chan.c`), so the union on `#λ`'s root works from `slash`. The mount table is shared, so a bind or mount made by either personality is seen by both. `dot` is kept across exec, so the working directory survives a change of personality. A Chan's path is the name it was reached by in the view that opened it, so an exec that changes personality renames `dot`'s path for the new view: going to Linux, a path under `/tmp` or `/mnt/term` is kept and any other gets a `/9` prefix; going to 9front, `/9` is stripped and any other path gets a `#λ` prefix. Paths under `/tmp`, `/mnt/term` (which includes the cwd at `/mnt/term/cwd`) and `/dev/fd` name the same files in both views. The rest of the 9front tree is at `/9` in the Linux view, so `/9/bin/ls` is 9front's `ls`, and a 9front process reaches the Linux tree as `'#λ'`, quoted in rc, or binds it where it likes. The 9front root is read-only, so h9 doesn't bind it anywhere by default. A `getcwd` whose directory is only in the 9front tree is reported under `/9`.

- **The Linux root.** `--root DIR` names it, as for a 9front root (see CLI and API). It's read-only by default and under the same access rules as the 9front root: `--writable DIR` makes it writable, and [overlay](0011-overlay.md)'s `--write=overlay` covers it once that's built. It's a contained tree under [symlinks-in-root](0034-symlinks-in-root.md), so Alpine's absolute links, such as `/bin/ls` to `/bin/busybox`, resolve inside it.
- **`/dev`:** `null`, `zero`, `full`, `random`, `urandom`, served by devlinux; `tty` and `console`, which open the machine's console; `fd`, which is devdup; and `stdin`, `stdout`, and `stderr` as `fd/0` to `fd/2`.
- **`/proc`:** `/proc/self`, `/proc/thread-self`, and `/proc/<pid>/{exe,cwd,maps,fd,stat,status,cmdline,environ}`, plus `/proc/cpuinfo`, `/proc/meminfo`, `/proc/stat`, `/proc/uptime`, `/proc/mounts` (a single root entry), `/proc/sys/kernel/random/uuid`, and `/proc/sys/vm/overcommit_memory` (`0`). `/proc/<pid>/fd` is listable, since CPython lists `/proc/self/fd` to close fds before exec. Pids are the machine's pids, so `/proc/<pid>` shows 9front processes too, with their a.out as `exe`. The `exe`, `cwd`, and `fd/N` entries read as symlinks to guest paths.
- **`/sys`:** only `/sys/devices/system/cpu/online` and `possible`, which read `0-N` for `--cpus` N+1. glibc's `sysconf(_SC_NPROCESSORS_ONLN)`, and so CPython's `os.cpu_count()`, read the first, and the answer agrees with `/proc/cpuinfo` and `sched_getaffinity`. The rest of `/sys`, cgroup files included, is absent. Go's runtime and other tools that look for cgroup limits treat a missing file as having no limit.
- **`--print`** shows the Linux view's binds, and the Linux root under `access:`.

Without a Linux root, a Linux binary run from a host path (`h9 ./prog`) gets the same view over an empty tree: `/9`, `/dev`, `/proc`, `/tmp`, and `/mnt/term`.

- **`/9` is there only when the machine has a 9front root.** Nothing in the personality reads the 9front tree: the Linux view's devices come from devlinux and the kernel. A machine with only a Linux root has no `/9`, and execing a 9front binary fails with `ENOENT` like any missing file. `/9` is what mixed pipelines and execing `rc` need.

**Environment.** A Linux process keeps its environment in its own memory, as Linux does. Going from 9front to Linux, execve builds envp from `/env`, turning rc lists into space-separated strings. Going from Linux to 9front, it writes envp into a new Egrp, so `rc` sees `$path` and friends as usual. `PATH` and `path` are kept separately: a Linux process starts with `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` unless the 9front side set `PATH`.

### CLI and API

- **`--root DIR` takes either kind of tree,** and h9 tells which by looking: a Linux tree has `/etc/os-release` or a `/lib/ld-*` loader, and a 9front tree has `/rc/bin` or `/$objtype/bin`. A 9P root costs a walk or two to check. `--root` may be given twice, once for each kind. When only a Linux tree is given, the 9front root comes from the usual lookup (`H9ROOT`, then the source tree's), and the machine has none if that finds nothing. A tree that's neither is used as a 9front root, as today.
- **`Machine.Options.linux_root`**: the Linux root, for embedders, who name it rather than having it detected.
- **Program resolution:** an absolute path or a bare name is resolved in the Linux view when the machine has a Linux root, through `PATH`, and in the 9front view otherwise. `--rc` always means 9front's rc. So `h9 --root alpine ls` runs busybox's `ls`, `h9 --root alpine /9/bin/ls` runs 9front's, and `h9 ls` is unchanged. After that, each personality searches only its own path.
- **Exit codes:** numeric statuses through [go-compat](0007-go-compat.md)'s rule; deaths by signal through [exit-status](0033-exit-status.md).

## Rationale

**gVisor compiled for Plan 9.**
- Go has no `plan9/arm64` port, so on arm64 hosts the Sentry would run under the emulator.
- gVisor needs a platform that runs untrusted code in an address space it controls and traps that code's syscalls: ptrace, seccomp traps, or KVM. A Plan 9 process has nothing like that.
- Its memory model maps a memfd into the guest at fixed addresses, and Plan 9 has no mmap.
- Each Linux syscall would cross four layers: Sentry, a Plan 9 syscall, an h9 exit, and drawterm.

h9's host process already sits where the Sentry would.

**linuxemu's approach, a translator running as a 9front program.** On arm64 and amd64, a Linux syscall doesn't fault; it reaches `syscall.dispatch` as a 9front call with the wrong registers, so there's no note to catch. The translator would also have to build epoll out of helper processes, one per fd, because it can't add readiness to a kernel it doesn't own.

**A Linux microVM beside h9.** It's the simplest way to run Linux, and Linux processes there are complete. But they aren't part of the machine: no shared namespace, no pipes to 9front processes, no 9P mounts in their file tree, and none of h9's sandbox policy. If that's all that's wanted, a microVM is the better tool, and h9 doesn't need this proposal.

**Detecting the root's kind, rather than a `--linux-root` flag.** A Linux tree and a 9front tree are easy to tell apart, and most runs want one or the other, so `h9 --root alpine sh` needs nothing more. A separate `--linux DIR` flag was the alternative: it's explicit, but it's a second way to name a root, and the two-root case is covered by giving `--root` twice.

**A real Linux kernel in a VM, beside the personality.** A sibling mode could boot a stock kernel on the same hypervisor, with its root served from h9's namespace over 9P2000.L ([dotl](0022-dotl.md)). It would get exact semantics for everything this proposal and its successors stub or leave out (io_uring, writable shared mappings, `/sys`), but its processes would be outside h9's process model, and it needs a full-guest vmm (EL1, a timer, an interrupt controller, virtio-mmio) that Unicorn can't provide. It's left for its own proposal, as a fallback for programs the personality can't serve rather than a replacement.

**One namespace, two roots, rather than binding the Linux root over `/`.** A bind over `/` in the shared Pgrp would change `/` for 9front processes too, so `rc` would find busybox's tools instead of its own and lose `/bin/rc` itself. A separate Pgrp for Linux processes (`RFNAMEG`) would keep 9front's view intact, but then a mount made by either personality would be invisible to the other, which loses the point. A per-process `slash`, as `chroot` gives, keeps one mount table and two views of it. devlinux's mount points mean the view's binds never need directories to exist in a read-only Linux root.

**`/tmp` and `/mnt/term` shared by path.** A pipeline that writes a file in one personality and reads it in the other needs the path to mean the same thing in both. The cwd lives under `/mnt/term`, so it survives a change of personality.

**uid 0, not 1000.** Alpine's `apk`, Debian's `dpkg`, and many install scripts refuse to run as non-root. Linux ids mean nothing to h9's access checks, so being 0 grants nothing beyond what the policy allows. Rootless containers make the same choice.

**Numeric exit statuses.** Linux programs and their callers, shell scripts and build tools, depend on exit codes. Carrying them as decimal strings is what APE already does, so `rc`'s `$status` reads the same either way, and APE's `wait` reads a Linux child's status correctly. The CLI side isn't Linux-specific: [go-compat](0007-go-compat.md) already maps numeric statuses, and [exit-status](0033-exit-status.md) maps deaths by signal.

**Splitting threads and networking out.** Each stage of the original plan was a step toward a different goal: dynamic binaries, then Go, then servers. Threads need cross-vCPU TLB shootdown and per-thread signals; readiness needs host-socket polling and `O_NONBLOCK`. Both are larger and riskier than the rest, and neither is needed to run busybox, Python scripts, or compilers. So stages 1 to 3 can be accepted, built, and used first. `vfork` stays here, because busybox can't run without it.

**The `stat` and errno mapping, shared with dotl.** [dotl](0022-dotl.md) needs the same mapping for 9P2000.L. Whichever is built first creates it as `src/dotl/attr.zig`, the path dotl names, and the other uses it. Neither depends on the other.

**A vDSO with only `__kernel_rt_sigreturn`, for now.** Go's arm64 runtime needs a signal return trampoline from the kernel, and a vDSO is where gdb and libunwind expect it; a bare trampoline page would work for Go but not for them. Every `clock_gettime` is still an exit, and Go makes a lot of them (594 of about 1,400 calls in the prototype's Go hello). Exporting `__kernel_clock_gettime` that reads the counter at EL0 would remove those, but it fixes the clock's layout into guest memory, so it's left for later work.

**Real stops, kept in the Linux personality.** Reporting stops through `wait4` while the stopped process kept running was the first plan. ash would then print its prompt and read the console alongside the job, which is worse than not supporting Ctrl-Z at all. Making `SIGTSTP` ignored by default was the cheaper alternative, but busybox's shell and most interactive tools expect it to work. Signals are already delivered in the host's exit loop, not in drawterm's kernel, so a stop is a sleep at that point, and 9front's process model doesn't need a stopped state. The remaining gaps are a stop that waits for a blocked call to return and the lack of `SIGTTIN` and `SIGTTOU`, and neither one causes a wrong result.

**Refusing shared file mappings, rather than a write-back at `msync`.** Writing dirty pages back at `msync`, `munmap`, and exit was the alternative. It would make LMDB's writes reach the file, but not keep two processes' mappings coherent, and SQLite's WAL index exists to be shared between processes. A wrong answer that shows up as a corrupt database is worse than `ENODEV` at `mmap`, so these programs fail at the start until mappings can be shared properly.

**Stubbing the out-of-scope calls rather than leaving them absent.** `-ENOSYS` from h9 means "not known to h9", and `--debug` names those calls so the ones that matter can be found. The calls in the table's last row are known: programs probe them and fall back, and the answer that's right for h9 is the one a seccomp-restricted container gives. Listing them keeps them out of the `--debug` output. `seccomp` is refused so that nothing believes a filter is enforced. `io_uring_setup` is listed because a reported release of 6.1 makes libuv try it.

**The emulator in virtual-TLB mode, not incremental region sync.** Syncing only the changed ranges was the first plan, but the cost is inside Unicorn: every region change rebuilds its memory map, so changing fewer regions still pays for all of them.

## Compatibility

- **`--root` accepts a Linux tree,** and may be given twice; a new `Machine.Options` field. A tree that's neither kind is a 9front root, as today.
- **New device** `#λ`. It's never masked: it serves nothing from the host itself, and what's bound into it is under the policy.
- **Exit codes:** an ELF binary for the wrong architecture is exit 126, like a bad a.out. Numeric statuses come from [go-compat](0007-go-compat.md), and deaths by signal from [exit-status](0033-exit-status.md).
- **vmm interface:** `unmap` takes a length, and `protect` and `hwcaps` are new (see vmm changes). The `none` backend gains stubs. The emulator's switch to virtual-TLB mode is internal to it.
- **9front processes** see no change unless they exec a Linux binary or use `#λ`.

## Security

- **The guest reaches nothing new on the host.** Every Linux call is served by drawterm's kernel through the same namespace, device mask, and policy hooks. The Linux root is under the access rules like the 9front root.
- **`rt_sigreturn`** must sanitize the restored state exactly as `noted` does (see Signals). It gets its own tests, including a forged frame that asks for EL1, or for kernel selectors on amd64.
- **The Linux root's symlinks** are resolved by [symlinks-in-root](0034-symlinks-in-root.md), which never steps above the tree and still checks the resolved path.
- **devlinux's `/proc` and `/sys`** must not reveal host details beyond what the policy already does. `/sys`'s CPU files report `--cpus`. `/proc/cpuinfo` and `/proc/meminfo` report the machine's limits (`--cpus`, `--memory`) and the guest-visible features, not the host's. `/proc/<pid>/exe` and the other links show guest paths. `/proc/mounts` doesn't list host paths. Pids are the machine's, so another machine's processes aren't visible, as with devproc.
- **uid 0 inside the Linux root** grants nothing: no h9 check reads Linux ids.
- **New attack surface:** the ELF loader and the VMA layer turn guest-supplied sizes and offsets into host mappings. Both validate against the address-space limits before mapping, as the a.out loader does, and the vmm's range `unmap` and `protect` refuse ranges outside the user half. Lazy faults allocate only inside VMAs, and count against `--memory`.

## Done when

Integration cases tagged `[linux-personality]`. The fixtures are static and dynamic musl binaries and an Alpine minirootfs, fetched by `scripts/fetch.sh` at a pinned release.

1. **Static binaries:** `h9 ./hello-musl` prints hello on HVF and on the emulator, for arm64, and for amd64 on the emulator.
2. **busybox:** `h9 --root alpine sh -c 'ls / | wc -l'` runs busybox's shell, which uses `vfork`. A mixed pipeline works both ways: `h9 --root alpine sh -c '/9/bin/ls /9/bin | wc -l'` and `h9 --root alpine --rc "ls /bin | '#λ/bin/busybox' wc -l"`.
3. **Dynamic binaries:** Alpine's dynamically linked tools (`apk --version`, `python3 -c 'print(1)'`) run. CPython scripts that use `subprocess` with pipes need [linux-net](0050-linux-net.md)'s `poll`.
4. **The emulator is usable for allocation-heavy programs:** `python3 -m pip --version` runs on the emulator within a few times its HVF time.

Cases:

- `test "static musl hello [linux-personality]"`
- `test "exit status 3 from a Linux program is h9's exit 3 [linux-personality]"`
- `test "wait4 reports a child killed by SIGSEGV [linux-personality]"`
- `test "rc runs a Linux program and reads its status [linux-personality]"`
- `test "vfork child execs while the parent waits [linux-personality]"`
- `test "mmap PROT_NONE reservation uses no memory until touched [linux-personality]"`
- `test "munmap and mprotect on part of a mapping [linux-personality]"`
- `test "SIGINT handler runs and rt_sigreturn resumes [linux-personality]"`
- `test "forged rt_sigreturn frame can't reach EL1 or kernel selectors [linux-personality]"`
- `test "a bind made by a 9front process is seen by a Linux one [linux-personality]"`
- `test "cwd survives exec across personalities [linux-personality]"`
- `test "/proc/cpuinfo reports --cpus, not the host [linux-personality]"`
- `test "--root detects a Linux tree; no /9 without a 9front root [linux-personality]"`
- `test "openat with a dirfd inherited from a 9front process [linux-personality]"`
- `test "failed execve returns ENOENT to the caller [linux-personality]"`
- `test "arm64 handler without SA_RESTORER returns through the vDSO [linux-personality]"`
- `test "SIGSTOP parks a Linux process until SIGCONT, and wait4 reports both [linux-personality]"`
- `test "VSUSP on a raw ISIG console stops the foreground group [linux-personality]"`
- `test "MAP_SHARED of a file opened for writing is ENODEV [linux-personality]"`
- `test "stubbed calls return their fixed answers, not ENOSYS [linux-personality]"`

## Implementation

1. A personality on the process record, the dispatch switch in `Machine.loop`, the ELF loader, the stack and auxv, the minimal vDSO, `Backend.hwcaps`. Static musl hello, on arm64 and then amd64.
2. File, process, and terminal calls, with amd64's older forms; the errno and `stat` mapping; exit statuses; `wait4`; `vfork`; signals for the common notes, and stops with the console's `ISIG` handling; devlinux and the Linux view, with Chan-relative dirfd walks; root detection in `--root`. busybox and the mixed pipelines. Needs [symlinks-in-root](0034-symlinks-in-root.md).
3. The vmm range `unmap` and `protect`, sorted regions on HVF, and the emulator's virtual-TLB mode; the VMA layer with lazy pages, faulted in by `guestmem` too; `PT_INTERP`. Dynamic binaries, and `pip --version` on the emulator.
4. DESIGN.md gets a "Linux personality" section.

## Open issues

- **Shared file mappings, for a later proposal.** SQLite in WAL mode and LMDB need writable `MAP_SHARED` file mappings that stay coherent. A likely design is a machine-wide table of shared file objects, keyed by the Chan's type, device, and `qid.path`. Every shared mapping of a file would use the same guest-physical pages, as shared anonymous mappings do. Linux `read`, `write`, and their variants on that file would go through those pages, and dirty pages would be written back at `msync`, `munmap`, the last `close`, and exit. Coherence would hold only within one machine: writes by 9front processes through other paths, or by other 9P clients, wouldn't be seen. `memfd_create` belongs with it, since it's mostly used with `MAP_SHARED`.

## Updates

- 2026-11-07: Choices made in the first implementation, which covers stages 1 and 2 and most of 3:
  - drawterm's `namec` doesn't walk mounts on a `#` path, so `#λ/bin` would never reach the Linux root. `third_party/drawterm/kern/chan.c` exempts `#λ`, the one change to the vendored tree. Reading the interpreter and resolving a Linux `PATH` from a 9front process also swap the process's root to the Linux view for the walk.
  - A process's dot is renamed when it changes views (`/9/x` ↔ `/x`, `#λ/x` ↔ `/x`, with `/tmp`, `/mnt/term` and relative paths kept), and kept only if the new name reaches the same file.
  - `pause`, `rt_sigsuspend`, `rt_sigtimedwait`, `nanosleep`, `clock_nanosleep`, `poll`, `ppoll`, `select`, `pselect6` and `epoll_wait` return `EINTR` after a handler whatever `SA_RESTART` says, as Linux does.
  - A note that maps to no signal kills a Linux process, as an uncaught 9front note would, rather than being dropped.
  - Job-control stops are not in yet: `SIGSTOP`, `SIGTSTP`, `SIGTTIN` and `SIGTTOU` are ignored, so the stop cases stay pending.
  - amd64 has no vDSO; musl and glibc fall back to the syscalls. `AT_HWCAP` is a constant per architecture (FP and ASIMD on arm64, the baseline x86-64 bits on amd64) rather than `Backend.hwcaps`.
  - `isatty` on the console is true only when h9's own stdin and stdout are both terminals, so `ls` doesn't color a pipe. The console's termios is one per machine.
  - `rename` across directories is `EXDEV`, `chown` succeeds without doing anything, and `symlink` and `link` are `EPERM`.
  - `/tmp` in the Linux view is the 9front `/tmp` when there's a 9front root, and an ephemeral overlay of its own otherwise.
  - The emulator's virtual-TLB mode and the vmm's range `unmap` and `protect` aren't in this change, so dynamic programs work on the emulator but one that maps a lot, such as Python, starts slowly (about a minute for `python3 -c 'print(1)'`).
- 2026-11-07: Found running ZeroFS 2.3.6 (a static Rust binary) and a survey of Alpine's busybox:
  - Until virtual-TLB mode lands, the emulator syncs only the regions that changed instead of remapping all of them, and flushes translated blocks only when a region went away. Anonymous memory comes in 1 MiB chunks rather than 64 KiB, so a program that touches a lot of memory makes a sixteenth of the regions. Together these took ZeroFS's server from not starting in 10 minutes to ready in about 20 s.
  - A machine whose processes are only slow to tear down (an engine with many regions takes seconds to close) waits for them rather than reporting `h9: machine stopped`.
  - `link` makes a copy with an exclusive create, since 9P has no hard links. That keeps the "create if absent" that object stores and lock files use `link` for, but the two names don't share later writes. `symlink` is still `EPERM`.
  - A Linux parent now gets `SIGCHLD` when a child exits, as the Proposal says; without it busybox `sh`'s `wait` on a background job hung.
  - A wildcard announce (`*`, or a Linux socket bound to `::`) uses IPv4 on a host without IPv6 sockets (`third_party/drawterm/kern/devip-posix.c`), so busybox `nc -l` works there.
  - ZeroFS's amd64 build uses AVX2 unconditionally on one path, which Unicorn's x86 CPU doesn't have; its arm64 build runs.
- 2026-11-07: `symlink` is built, since `apk add` makes links for every shared library and busybox applet. In an overlay (the root, and `/tmp`) a link is a node in memory that walks follow, an absolute target from the overlay's own top, which is the process's root only for the root overlay; a final link whose target is missing is walked to as itself, so it can be renamed and removed. In a host tree it's a host `symlink()`, the new name checked like a create; a host process following it later isn't checked by h9, as with any file the guest writes. A dangling host link can't be walked to yet, so `ls -l` of one fails. `wait4` with `WNOHANG` while children are running returned `ECHILD` from a stale error string, which SIGCHLD made busybox `sh` hit; it returns 0 now.
- 2026-11-07: The emulator's virtual-TLB mode is built, as the Proposal describes, with these choices:
  - Guest pages come from one arena reserved at twice `--memory` (`src/vmm/arena.zig`), mapped into each engine once as its physical memory. A freed range goes back to the host rather than being cleared by hand.
  - The engine keeps a sorted copy of the address space's regions for the fill hook, not a page table: the regions are already page runs, and a binary search over them is cheap next to a fill.
  - Unicorn's fill hook sees only the page, and a refused fill raises an exception without the address, which `si_addr` needs. So a refused access gets a trap entry, a physical page with nothing behind it, and reaches the unmapped-memory hook with its offset; the fault is the page plus that offset.
  - Translated blocks are dropped only with an executable region, over its physical range, instead of flushing every block whenever any region goes away.
  - `apk add --no-cache jq` from a stock Alpine root (on a Linux x86_64 VM, fetching the package index over the network) went from 792 s to 108 s on arm64, and about the same on amd64. CPU-bound code gains less, because the incremental sync had already taken most of the map rebuilds away: a Python loop of 100,000 `json.dumps` calls on the arm64 emulator went from 132 s to 115 s, and `python3 -c 'print(1)'` stays at about 6 s. Most of the remaining time is Unicorn's code itself. It calls a helper after every guest load and store to check for an exit request, and the time-slicing block hook costs about 20% (93 s without it). Both would need a Unicorn patch, which only the source build (`-Dunicorn=source`, used for releases) can carry.
- 2026-11-08: What SQLite needs of files, found running it from Python and the `sqlite3` shell, is built. These move out of Stubbed and the Memory list's refusals:
  - Record locks are real. `F_SETLK`, `F_SETLKW` and `F_GETLK` keep POSIX locks per process, released when it closes any fd of the file or ends; the `F_OFD_*` forms keep them per open file description, which is the kernel's Chan, since `dup` and `fork` share it. `flock` is the same table's separate whole-file lock, as on Linux. The table spans every machine in the h9 process, keyed by the file's device type, instance and `qid.path`. A blocking request polls every 2 ms, since the kernel has no wait queue for it, and a signal ends it with `EINTR`. Without locks, a second writer rolled back the first's hot journal, so the first's `COMMIT` failed with `SQLITE_IOERR`, and concurrent writers lost rows.
  - Shared file mappings, writable or not, are served by the table Open issues sketched, with these choices. It spans every Mm on one backend, not only one machine's. A shared mapping takes 1 MiB chunks of its own, the rest of each padded with VMAs the guest doesn't see. A file mapping sits at its file offset's place in a chunk, so `mmap` with `MAP_FIXED` elsewhere is `ENODEV`, and `mremap` of a shared mapping is `EINVAL` unless it keeps its size. Pages are written back only when the last mapping goes, not at `msync`, since other processes already share them, and only if a mapping could write. `PROT_WRITE` with `MAP_SHARED` needs an fd open for reading and writing (`EACCES`), as on Linux. The Linux layer's `read`, `write`, `pread64` and `pwrite64` (not the vectored forms) see and update the mapped pages, and `ftruncate` zeroes what's past the new end. SQLite's WAL mode works across processes. `memfd_create` is still left out.
  - `fsync` and `fdatasync` reach the host's `fsync` through a wstat that changes nothing (`third_party/drawterm/kern/devfs-*.c`); a device that keeps no data, or a 9P server that refuses the wstat, has nothing to sync.
  - A `pread64` of 16 KiB or less reads 128 KiB ahead into a cache per fd. SQLite's `integrity_check` reads one page per call, about 56,000 calls on the database that was measured. The cache is dropped on any write or truncate through the Linux layer, any change to the lock table (SQLite takes a lock before it reads), and after a second, which bounds how long a write from outside the Linux layer can go unseen.
  - `wait4`, `waitid` and `getrusage` fill `struct rusage` with CPU time measured on the host thread each guest thread runs on (`RUSAGE_THREAD` on Linux, `thread_info` on macOS, `GetThreadTimes` on Windows), and `ru_maxrss` from the allocated chunks. User time includes the guest's own instructions as the host counts them. A group's leader puts the group's time, and its reaped children's, in its kernel wait record (`Hproc.cputime`, which `pexit` copies), so a 9front parent's `await` sees it too. `CLOCK_PROCESS_CPUTIME_ID` still reads 0.
  - `#λetc` was bound after the root's `/etc` without `MCREATE`, so nothing could be created in `/etc` ("mounted directory forbids creation"), and `apk` failed. The root's `/etc` is now bound over itself with `MCREATE` first.
  - A rename of a dangling host symlink stat'ed its missing target in `#U`'s wstat and failed with `ENOENT`; it falls back to `lstat` of the link. It didn't reproduce on a Linux host, only in a report from an HVF run.
- 2026-11-08: PostgreSQL 17 (Alpine's `postgresql17`) installs, runs `initdb`, and serves queries over TCP on the arm64 emulator. What it needed:
  - `apk` renames a dangling symlink into place, and `#U` couldn't walk to one: its walk followed the link and failed. `third_party/drawterm/kern/devfs-posix.c` now walks to a final name that is a link to nothing as the link itself, checked as a name (`h9_fs_checkname`) since there is no target to check, and its `stat` and `wstat` use `lstat`. The 2026-11-07 note's dangling host link that couldn't be walked to is fixed with it.
  - `initdb` refuses to run as root, and `su` needs `setgroups`, so the set-id calls move out of Stubbed. Each process keeps real, effective and saved uids and gids and its supplementary groups, inherited across `fork` and `exec`; root may set any, others only among their own. `stat` reports files as owned by the caller's effective ids, since PostgreSQL checks that it owns its data directory.
  - The postmaster's interlock is a System V shared memory segment, which the table left absent. `shmget`, `shmat`, `shmdt` and `shmctl` are built on chunk pages.
  - Its locks are musl's process-shared semaphores, futexes in its anonymous `MAP_SHARED` memory. A futex there is keyed by the pages, not the `Mm`. And `fork` shared only the chunks the parent had touched, so the shared buffers a backend read into were its own: another backend saw a page as zeros ("index contains unexpected zero page"). `fork` now makes the untouched chunks of a shared mapping first.
  - The latch is `signalfd` with `epoll`, and timeouts are `setitimer`. Both are built (see DESIGN.md).
  - `pgbench -i` on an HVF Mac found `fallocate` absent, which PostgreSQL 17 doesn't fall back from. Mode 0 now grows the file with a truncate up, `FALLOC_FL_KEEP_SIZE` does nothing, and the hole modes are `EOPNOTSUPP`. The size it compares against was read from the wrong offset of the stat buffer, and so were `fcntl`'s `SEEK_END` lock base and the shared-mapping write-back's file length, which could write a chunk's pages past the file's end.
  - Named `AF_UNIX` sockets, PostgreSQL's default for local connections, came next (see [linux-net](0050-linux-net.md)'s Updates), so psql connects without `-h`. IPv6 `::1` doesn't listen ("I/O error"). The postmaster's fd probe trips 9front's "process exceeds 100 file descriptors" warning, ten times. `initdb` takes about a minute on the arm64 emulator.
- 2026-11-08: age 1.2.1 and passage 1.7.4 (Alpine's `age`, `passage`, `git`, `tree`) on the amd64 emulator: keygen, encryption to keys, files and passphrases, and every passage command but the clipboard and QR ones, with its git store. What they needed:
  - A Plan 9 pipe keeps write boundaries, so an empty `write` reached the reader as an end of file. age writes an empty buffer to stdout before the plaintext, so `age -d f | cat` printed nothing and passage showed no passwords. An empty write to a pipe now does nothing.
  - A pipe write queues its block (up to 64 KB) before it waits for room, so a note during the wait failed a write whose data was already sent. Go's SIGURG preemption hit it, and Go retried, so `age -d` of a large file into a pipe repeated 32 KB pieces. A pipe write is now one block per kernel write, and an interrupted block counts as written, as Linux returns the bytes written before a signal.
  - `TCGETS` wrote 60 bytes, musl's `struct termios`. The kernel's is 36, and Go's 44, so `age -p` on a terminal overwrote a return address and crashed. It writes 36.
  - `/dev/shm` was an empty read-only directory, so passage's `mktemp -d /dev/shm/...` for `edit` and its git `textconv` failed. It's an ephemeral overlay of its own now, as a tmpfs is.
  - Without a 9front root, `#λ/mnt/term` had no `cwd` to bind on, so the cwd landed at `/mnt/term`. devlinux serves `/mnt/term/cwd` as a mount point.
  - Still open: `link` makes a copy, which git's local `clone` refuses ("hardlink different from source", since 2.45 checks the inode); `git clone --no-hardlinks` and `file://` work.
- 2026-11-08: Redis 8.0.4 (Alpine's `redis`) installs and runs with its default configuration: commands, `redis-benchmark`, BGSAVE (fork), AOF with rewrite, and reloading from either. What it needed:
  - Reading `/proc/n/stat` or `status` overran the kernel's stack and crashed h9 on the amd64 emulator (arm64 printed 0 for vsize and rss). drawterm's `ulong` is 32 bits, and the Zig hooks wrote 64-bit values through `ulong*`. Redis reads `/proc/self/stat` every second.
  - `rename` across directories, which was `EXDEV` (2026-11-07), is the host's `rename(2)` when both names are in host trees, checked as a rename of the old name and a create of the new one, so it replaces the target atomically. Redis's AOF moves each rewrite into `appendonlydir` and fails on `EXDEV`. It stays `EXDEV` in an overlay (the root without `--writable`, and `/tmp`), where `mv` copies, and on Windows hosts.
  - `madvise(MADV_FREE)` is `EINVAL`, as before Linux 4.5, rather than a hint: callers fall back to `MADV_DONTNEED`. On arm64 Redis tests for a copy-on-write kernel bug by reading `Shared_Dirty` from `/proc/self/smaps` after `MADV_FREE` and a fork, and refuses to start when it can't; `EINVAL` is its "not affected" answer. A `smaps` with honest zeros would make it report the bug instead, since h9's fork copies pages.
- 2026-11-08: A Linux program's `TCSETS` never reached the host terminal: the hook it called was never set, so `read -n1` waited for a newline and `vi` got lines. It now sets the console's raw mode from `ICANON`, and its echo from `ECHO` (raw mode with echo, as `read -n1` asks for, echoes; 9front's `rawon` still turns both off), so a password typed at `read -s`, `stty -echo` or age's prompt isn't shown, and the line can still be edited. The console's hook (`Machine.Stdio.raw`) has an optional `echo` for this, and consctl takes `echooff` and `echoon`, which keep the line discipline; the last consctl close and the end of a run turn echo back on. busybox `read` polls before it reads, and a poll on the console never asked the host for input, so it waited forever: a poll for input now asks for a read, as a read does, and the input wakes pollers.
- 2026-11-08: Zig 0.16.0 (the static release, unpacked in `/opt/zig` and linked from `/usr/bin/zig`) needed two changes before it could compile anything:
  - `/proc/self/exe` was the path the program was exec'd by, with its links unresolved. Zig finds its `lib` directory beside that path, so run through the link it looked in `/usr/bin` and failed with "unable to find zig installation directory". It's the absolute path with every link followed now, as Linux gives it.
  - `rename` across directories was still `EXDEV` in an overlay (the root without `--writable`, and `/tmp`). Zig builds each cache entry in `tmp/` and renames it into `o/`, treats `EXDEV` as fatal, and keeps its global cache in `~/.cache/zig`, so every compile failed. A rename within one overlay moves the node in memory now (`h9_overlay_move`), replacing a file, a link or an empty directory at the target, with a whiteout left where a lower name was. A directory still in the lower tree stays `EXDEV`, as in Linux's overlayfs without `redirect_dir`, and so does a rename between two overlays (the root and `/tmp`).
  - `renameat` with a relative new name and a different directory fd from the old name's was `EXDEV`, since both names have to resolve from one place. Zig renames from its `tmp/` fd into `o/`'s, so `zig cc` failed on a host-tree cache. The new name is joined to its directory's path now.
  - An open file renamed on the host kept its old path in devfs, so `ftruncate`, `fchmod`, and `fstat` on it were `ENOENT`. Zig moves its output into the cache and then truncates it, so `zig test` and `zig build` failed with "ELF flush failed: Unexpected". devfs stats an open file through its host fd, and changes one open for writing through the fd when its path no longer names it.
  - `readv` went on to the next buffer after filling one, so from a pipe it waited for more data that hadn't been sent. Zig's test runner reads its 8-byte request into the first of two buffers, and `zig build test` timed out after a minute. From anything but a file, `readv` stops at the first buffer it fills, and returns what it has, as Linux does.
  - On arm64 every compile died with SIGSEGV on HVF, `zig env` included: Zig (and LLVM's host detection) reads `MIDR_EL1` and the `ID_AA64` registers with `mrs` at EL0, which Linux traps and emulates (`HWCAP_CPUID`), and h9 took the trap for a fault. An EL0 `mrs` in the ID space is emulated now, with the values `AT_HWCAP` already gave: MIDR an Armv8 part of implementer 0 (as `/proc/cpuinfo` says), MPIDR its RES1 bit, REVIDR 0, and every feature register 0, which is Armv8.0 with FP and Advanced SIMD. `AT_HWCAP` and `/proc/cpuinfo` add `cpuid`. The emulator doesn't trap these reads, and its CPU answers for itself.
  - `zig cc` hung on HVF. Zig holds its cache locks (`flock`) on close-on-exec fds while it forks clang, so a child could hold the last fd of a lock's open file once the parent closed its own, and when exec closed that fd the lock stayed, with every later `flock` on the file waiting for good. Exec releases what closing each close-on-exec fd releases now, as `close` does.
  - Still open: with the default 1 GB, `zig cc` from a cold cache and `zig build -Doptimize=ReleaseFast` fail to spawn zig's clang and LLD children ("SystemResources"): exec copies the whole 170 MB `zig` image into each child's memory. `--memory 3g` is enough for `zig cc`, but not on HVF for a cold `zig build test` or `zig build -Doptimize=ReleaseFast` of a `zig init` app, which fail the same way; `--memory 6g` works. [cow-fork](cow-fork.md) proposes the fix. On the amd64 emulator a cold `zig build-exe` of hello world takes about 10 minutes against 5 s natively, mostly in Unicorn's slow-path stores and TLB refills.
- 2026-11-08: fzf 0.62, ripgrep 14.1, htop 3.4, btop 1.4, and bat 0.25 (Alpine's packages) on the amd64 emulator. ripgrep and bat worked as they were; the others needed:
  - Raw mode kept the host terminal's `ICRNL`, so Enter reached the program as Ctrl-J. fzf binds that to "down", so Enter moved the cursor and never accepted. A `TCSETS` without `ICRNL` now clears it on the host too, through an optional `crnl` on the console's hook (`Machine.Stdio.raw`).
  - btop reads with `VMIN` 0 and `VTIME` 0 until a read returns nothing, and the console's read waited for input, so btop stopped redrawing after the first key. A non-canonical termios with `VMIN` 0 now makes a console read wait at most `VTIME` tenths of a second and return 0 bytes if nothing came.
  - `TIOCGWINSZ` was always 80x24. It's the host terminal's size, from an optional `size` on the same hook, or 80x24 when the host can't say. A resize isn't passed on as `SIGWINCH` yet.
  - htop drops a process whose `/proc/n/statm` it can't read, and reads the leader's `stat` as `/proc/n/task/n/stat`, so it listed nothing. devlinux serves `statm` (sizes in pages from the process's memory) and `task`, whose entries are the thread group's threads, each the same directory as `/proc/tid`. `/proc` itself lists only each thread group's leader, as Linux does, so btop no longer shows a thread as a second process.
  - Still open: CPU times in `/proc/stat` and `/proc/n/stat` are zero, so htop and btop show 0% (htop "N/A"), and every process's state is `R` or `S` from its 9front state.
