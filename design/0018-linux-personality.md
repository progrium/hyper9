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

## Abstract

h9 runs Linux ELF binaries next to 9front ones, in the same machine. A process's personality is chosen at exec by its binary format. A Linux process's syscalls are served by a second syscall table in the host, translated onto the same drawterm kernel. So Linux processes share the machine's mount table, file descriptors, pipes, notes and sandbox policy with 9front processes, and the two can pipe to each other and exec each other. Each process has its own root: a Linux process's `/` is a Linux root tree, such as Alpine's minirootfs, with the 9front tree at `/9`. This proposal covers single-threaded programs, static and dynamic. Threads ([linux-threads](linux-threads.md)) and readiness with sockets ([linux-net](linux-net.md)) are their own proposals, built on this one.

## Background

h9 already has the shape of a syscall-translating kernel. Each guest process runs in user mode on a vCPU, a syscall exits to the host, and a kernel in the host serves it (DESIGN.md, Architecture). gVisor has the same shape: its KVM platform is h9's vmm layer, and its Sentry is drawterm's kernel. What's missing is a second ABI.

Linux binaries trap with the same instructions as 9front's: `SVC` on arm64 and `SYSCALL` on amd64. So a Linux syscall already arrives as the vmm's `.syscall` exit, with every register the Linux ABI uses already in the Ureg:

- **arm64:** the number in x8, arguments in x0 to x5, the result in x0.
- **amd64:** the number in rax, arguments in rdi, rsi, rdx, r10, r8 and r9, the result in rax.

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

## Proposal

### Personality and dispatch

Each process has a personality, `plan9` or `linux`, set by exec from the binary's magic: the a.out magics as today, or `\x7fELF`. On a `.syscall` exit, `Machine.loop` dispatches to `syscall.dispatch` or `linux.dispatch` by personality. Both return the existing `Outcome` union:

- `exits` for `exit` and `exit_group`
- `rfork` for `fork`, `vfork` and `clone`
- `exec` for `execve`
- `noted` for `rt_sigreturn`, with a Linux frame (see Signals)

A Linux process can execve a 9front binary and the reverse. Each exec picks the personality anew, and sets the process's root to match (see The Linux view).

### The ELF loader

For a static or dynamic ELF64 executable of the host's architecture:

- Map the `PT_LOAD` segments with their permissions. For a dynamic one, load the `PT_INTERP` interpreter at a fixed high base. `PT_GNU_STACK` is honoured: the stack is never executable unless it asks.
- Build the Linux initial stack: argc, argv, envp, then the auxv with `AT_PHDR`, `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ` (4096), `AT_BASE`, `AT_ENTRY`, `AT_RANDOM`, `AT_HWCAP`, `AT_HWCAP2`, `AT_CLKTCK` (100), `AT_SECURE` (0), `AT_UID` and friends, and `AT_EXECFN`.
- `AT_HWCAP` and `AT_HWCAP2` report what the guest can actually use, which differs between HVF and the emulator. The backend reports them (see vmm changes).
- Give no vDSO (`AT_SYSINFO_EHDR`). musl and glibc fall back to real syscalls without one.

Linux processes have no Tos.

### Syscalls

`src/linux/` holds the table, one entry per Linux syscall number per architecture. Calls map onto drawterm's `sys*` wrappers on the calling Proc, as `syscall.zig`'s do. Results are Linux's: a value, or `-errno`.

Every entry is one of three kinds, so `-ENOSYS` always means "not known to h9":

- **Served:** translated onto the kernel, as in the table below.
- **Stubbed:** a fixed answer that's right for h9, listed in the table's last rows.
- **Absent:** `-ENOSYS`, and with `--debug` a line naming the call, so the gaps that matter can be found.

| Area | Calls | Served by |
| --- | --- | --- |
| Files | `openat`, `read`, `write`, `pread64`, `pwrite64`, `readv`, `writev`, `lseek`, `close`, `dup`, `dup3`, `fcntl`, `pipe2`, `getdents64`, `newfstatat`, `fstat`, `statx`, `faccessat`, `faccessat2`, `mkdirat`, `unlinkat`, `renameat`, `renameat2` (flags 0), `fchmod`, `fchmodat`, `fchownat`, `utimensat`, `ftruncate`, `truncate`, `fsync`, `fdatasync`, `getcwd`, `chdir`, `fchdir`, `readlinkat`, `statfs`, `fstatfs` | drawterm's file calls. Relative paths with a dirfd are joined to the dirfd's path from `fd2path`. `stat` is built from a Plan 9 `Dir` (see Users and `stat`). `readlinkat` and `lstat`-style calls see links in trees resolved by [symlinks-in-root](0034-symlinks-in-root.md), and `EINVAL` elsewhere. `utimensat` and `fchownat` become a `wstat`. |
| Processes | `clone` (without `CLONE_VM`, or with `CLONE_VM` and `CLONE_VFORK`), `fork`, `vfork`, `execve`, `execveat`, `exit`, `exit_group`, `wait4`, `waitid`, `getpid`, `getppid`, `gettid`, `set_tid_address`, `kill`, `tgkill`, `tkill`, `setsid`, `setpgid`, `getpgid`, `getsid` | h9's process model (see Processes) |
| Memory | `brk`, `mmap`, `munmap`, `mprotect`, `madvise` (`DONTNEED` zeroes, the rest are hints), `mremap` | The VMA layer (see Memory) |
| Signals | `rt_sigaction`, `rt_sigprocmask`, `rt_sigreturn`, `rt_sigpending`, `rt_sigsuspend`, `rt_sigtimedwait`, `sigaltstack` | See Signals |
| Time | `clock_gettime`, `clock_getres`, `clock_nanosleep`, `nanosleep`, `gettimeofday`, `times` | The host clock, the same one [go-compat](0007-go-compat.md) uses for `/dev/bintime`. `CLOCK_PROCESS_CPUTIME_ID` and `CLOCK_THREAD_CPUTIME_ID` read 0 until there's per-thread CPU accounting, as `/proc/n/status` does. |
| Terminal | `ioctl` `TCGETS`, `TCSETS*`, `TIOCGWINSZ`, `TIOCGPGRP`, `TIOCSPGRP` on the console; `FIONREAD` | `TCSETS` with `ICANON` off writes `rawon` to `/dev/consctl`, and `rawoff` when it's on again. `isatty` and line editing work. Other ioctls are `-ENOTTY`. |
| Other | `uname`, `getrandom`, `sysinfo`, `getuid` and the other id calls, `umask`, `prctl` (`PR_SET_NAME`, `PR_GET_NAME`, `PR_SET_PDEATHSIG`), `arch_prctl` (amd64 `ARCH_SET_FS`, `ARCH_GET_FS`) | Fixed answers, or the host where it's safe. `uname` is `Linux`, release `6.1.0-h9`, with the machine's architecture; the node name is `sysname`. |
| Stubbed | `prlimit64` and `getrlimit` (the machine's limits: `--memory` for `RLIMIT_AS`, 1024 files), `setrlimit` (accepted, ignored), `sched_getaffinity` (the `--cpus` count), `sched_yield`, `getpriority`/`setpriority`, `membarrier` (`-EINVAL` for every command but query), `rseq` (`-ENOSYS`, which glibc expects), `set_robust_list` (accepted; see [linux-threads](linux-threads.md)), `setuid` and the other set-id calls (success when the id is unchanged, else `-EPERM`), `chroot`, `mount`, `umount2`, `pivot_root`, `unshare` (`-EPERM`; [dotl](0022-dotl.md) adds `mount -t 9p`), `linkat`, `symlinkat` (`-EPERM`) | |

Calls that need readiness (`poll`, `ppoll`, `pselect6`, `epoll_*`, `eventfd2`) and sockets come in [linux-net](linux-net.md). `fcntl` accepts and records `O_NONBLOCK` here, but reads and writes block until that proposal is built.

Error strings map to errno: "file does not exist" is `ENOENT`, "permission denied" is `EACCES`, "interrupted" is `EINTR`, "file already exists" is `EEXIST`, "not a directory" is `ENOTDIR`, "is a directory" is `EISDIR`, "write on closed pipe" is `EPIPE`, and unknown strings are `EIO`. The table lives in one place, shared with [dotl](0022-dotl.md) (see Rationale), and is tested on its own.

### Users and `stat`

`qid.path` becomes `st_ino`, and the device type and number become `st_dev`. Plan 9 modes become Linux modes, with `DMDIR` as `S_IFDIR` and the rest `S_IFREG`, except that devices under the Linux `/dev` report as character devices.

Inside the Linux root, the machine's user is uid 0 and gid 0, as in a rootless container. Package managers and many scripts refuse to run otherwise, and it grants nothing: every access is still decided by the namespace, devfs and the policy, which don't look at Linux ids. Other user and group names map to numbers through the Linux root's `/etc/passwd` and `/etc/group`, read when the machine starts, and any other name is 65534 (`nobody`). The reverse, for `fchownat`, is the same table; an unknown number is `-EPERM`.

### Processes

- **`fork`, and `clone` without `CLONE_VM`,** is `rfork` with `RFPROC|RFFDG` and the Linux address space copied (see Memory).
- **`vfork`, and `clone(CLONE_VM|CLONE_VFORK)`,** creates a child that shares the parent's address space, on the stack the caller gives, while the parent waits until the child execs or exits. musl uses this for `vfork` and `posix_spawn`, so busybox needs it. While the parent waits nothing else runs in the shared space, so it needs none of [linux-threads](linux-threads.md)'s TLB shootdown.
- **`clone` with `CLONE_VM` and without `CLONE_VFORK`** is `-ENOSYS` until [linux-threads](linux-threads.md).
- **`wait4` and `waitid`** map onto `await`, filtered by pid in h9 since `await` takes any child. Process groups (`setpgid`, `TIOCSPGRP`) are kept on the process for `wait4(-pgid)` and for job control's foreground group; the console's Ctrl-C still goes to the note group.
- **Exit statuses** map both ways. Linux `exit(0)` is `exits("")`, and `exit(n)` is `exits("n")` in decimal, as APE's `_exit` writes. A death by signal N is `exits("linux: signal N")`. For `wait4`, the reverse: `""` is status 0, a decimal string is that number modulo 256, `linux: signal N` is killed by signal N, a fault note is killed by `SIGSEGV`, and any other string is status 1.
- **The CLI** exits with a Linux program's status unchanged, through [exit-status](0033-exit-status.md). How a death by signal reaches the host is that proposal's open issue.

### Memory

A Linux address space is a list of VMAs, kept sorted, alongside the existing segments.

- **Lazy pages.** Anonymous VMAs, the heap and the stack get their pages on first touch: a `.fault` exit inside a VMA that allows the access allocates a page, maps it and resumes, as the stack grows today. A fault outside any VMA, or against its permissions, is `SIGSEGV`. A `PROT_NONE` reservation, however large, costs no guest-physical memory. Pages are mapped in chunks of up to 64 KiB where the VMA allows, to keep the backend's region count down.
- **`brk`** grows a heap VMA after the executable's last segment.
- **Private file mappings** are read through the kernel into fresh pages: eagerly for small files, or chunk by chunk on fault. `MAP_FIXED` replaces what's there, as musl's and glibc's loaders need.
- **Shared anonymous mappings** stay shared across `fork`, like segattach's `shared` segments.
- **Shared writable mappings of files** are refused with `ENODEV`. drawterm has no page cache to write them back through. Read-only shared file mappings are treated as private.
- **`fork`** copies the VMAs eagerly, as `rfork` copies segments. Copy-on-write is later performance work.
- **Limits.** Pages count against `--memory` when they're allocated, not when they're reserved, so a fault past the limit is `SIGSEGV` with a "virtual memory allocation failed" note under `--debug`. Virtual reservations are capped at the 47-bit user range.

### vmm changes

The `vmm` interface (`src/vmm.zig`) and both backends gain:

- **`AddressSpace.unmap(va, len)`** removes any page-aligned range, splitting regions as needed. Today's whole-region `unmap(va)` becomes a call with the region's length.
- **`AddressSpace.protect(va, len, perms)`** changes the permissions of any page-aligned range of mapped pages, splitting regions as needed.
- **Region lookup** in both backends is a sorted structure with logarithmic lookup, not a linear scan.
- **The emulator syncs incrementally:** a change maps, unmaps or re-protects only the affected ranges in each engine, and flushes translated blocks only for ranges that lost execute permission or changed contents under it.
- **`Backend.hwcaps()`** returns the guest-visible CPU features, for `AT_HWCAP`, `AT_HWCAP2` and `/proc/cpuinfo`.

A change that removes or narrows access must take effect before the host reuses the pages. With this proposal at most one vCPU runs in a Linux address space at a time (a `vfork` parent waits), so the existing epoch flush at the next run is enough. [linux-threads](linux-threads.md) adds the shootdown that concurrent threads need.

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

Linux processes signal each other with `linux: signal N` notes, so a 9front process can also signal one by writing to `/proc/n/note`. A Linux process whose child exits gets `SIGCHLD`, synthesized by h9 when the wait record is queued, unless its `SIGCHLD` action is `SIG_IGN`. A note posted to a 9front process from a Linux one is the note's string for the known signals (`interrupt` for `SIGINT`) and `linux: signal N` otherwise.

`rt_sigaction` handlers, the signal mask and the alternate stack are kept on the process. Delivery happens where notes are delivered today: at the top of the exit loop, and when a blocking call is interrupted, which returns `-EINTR` unless the handler has `SA_RESTART`. Delivery builds an `rt_sigframe` on the user stack, or the alternate stack, and enters the handler with the restorer as the return address. The frame is laid out exactly as Linux's, since libc and debuggers read it:

- **arm64:** `siginfo`, then `ucontext` with the general registers in `sigcontext` and, in its `__reserved` area, an `fpsimd_context` record, an `esr_context` record for faults, and the terminating null record.
- **amd64:** `siginfo`, then `ucontext` with `sigcontext` and a pointer to an `fxsave`-format FP state.

Default actions follow Linux: terminate, ignore (`SIGCHLD`, `SIGURG`, `SIGWINCH`), or stop. Stop and continue (`SIGSTOP`, `SIGTSTP`, `SIGCONT`) are recorded and reported through `wait4` with `WUNTRACED`, but the process keeps running; real job-control stops are an open issue.

`rt_sigreturn` restores the saved registers only after sanitizing them as `noted` does. On arm64 that means keeping only NZCV from the guest's PSR; on amd64, forcing the selectors and system flags. The HVF shim loads the PSR straight into `SPSR_EL1`, so this is the one place a forged frame could reach EL1.

### The Linux view

A Linux process's root is a small new device, `#λ` (devlinux, in `src/kern/`), not the machine's root. Its root directory holds `9`, `tmp` and `mnt/term` as mount points, and serves `dev` and `proc` itself. When the machine starts, the namespace builder adds binds to the shared Pgrp:

```text
bind -a '#U/path/to/alpine' '#λ'       ro
bind / '#λ/9'
bind /tmp '#λ/tmp'
bind /mnt/term '#λ/mnt/term'
```

exec of an ELF sets the process's `slash` to `#λ`'s root, and exec of an a.out sets it back to the machine's root. The mount table is shared, so a bind or mount made by either personality is seen by both. `dot` is kept across exec, so the working directory survives a change of personality. Paths under `/tmp`, `/mnt/term` (which includes the cwd at `/mnt/term/cwd`) and `/dev/fd` name the same files in both views. The rest of the 9front tree is at `/9` in the Linux view, so `/9/bin/ls` is 9front's `ls`, and a 9front process reaches the Linux tree as `'#λ'`, quoted in rc, or binds it where it likes. The 9front root is read-only, so h9 doesn't bind it anywhere by default. A `getcwd` whose directory is only in the 9front tree is reported under `/9`.

- **The Linux root.** `--linux-root DIR` names it. It's read-only by default and under the same access rules as the 9front root: `--writable DIR` makes it writable, and [overlay](0011-overlay.md)'s `--write=overlay` covers it once that's built. It's a contained tree under [symlinks-in-root](0034-symlinks-in-root.md), so Alpine's absolute links, such as `/bin/ls` to `/bin/busybox`, resolve inside it.
- **`/dev`:** `null`, `zero`, `full`, `random`, `urandom`, served by devlinux; `tty` and `console`, which open the machine's console; `fd`, which is devdup; and `stdin`, `stdout` and `stderr` as `fd/0` to `fd/2`.
- **`/proc`:** `/proc/self`, `/proc/thread-self` and `/proc/<pid>/{exe,cwd,maps,fd,stat,status,cmdline,environ}`, plus `/proc/cpuinfo`, `/proc/meminfo`, `/proc/stat`, `/proc/uptime`, `/proc/mounts` (a single root entry) and `/proc/sys/kernel/random/uuid`. Pids are the machine's pids, so `/proc/<pid>` shows 9front processes too, with their a.out as `exe`. The `exe`, `cwd` and `fd/N` entries read as symlinks to guest paths.
- **`/sys`:** absent.
- **`--print`** shows the Linux view's binds, and the Linux root under `access:`.

Without `--linux-root`, a Linux binary run from a host path (`h9 ./prog`) gets the same view over an empty tree: `/9`, `/dev`, `/proc`, `/tmp` and `/mnt/term`.

**Environment.** A Linux process keeps its environment in its own memory, as Linux does. Going from 9front to Linux, execve builds envp from `/env`, turning rc lists into space-separated strings. Going from Linux to 9front, it writes envp into a new Egrp, so `rc` sees `$path` and friends as usual. `PATH` and `path` are kept separately: a Linux process starts with `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` unless the 9front side set `PATH`.

### CLI and API

- **`--linux-root DIR`**: the Linux root.
- **`Machine.Options.linux_root`**: the same, for embedders.
- **Program resolution:** an absolute path or a bare name is resolved in the Linux view when `--linux-root` is given, through `PATH`, and in the 9front view otherwise. `--rc` always means 9front's rc. So `h9 --linux-root alpine ls` runs busybox's `ls`, `h9 --linux-root alpine /9/bin/ls` runs 9front's, and `h9 ls` is unchanged. After that, each personality searches only its own path.
- **Exit codes:** through [exit-status](0033-exit-status.md).

## Rationale

**gVisor compiled for Plan 9.**
- Go has no `plan9/arm64` port, so on arm64 hosts the Sentry would run under the emulator.
- gVisor needs a platform that runs untrusted code in an address space it controls and traps that code's syscalls: ptrace, seccomp traps or KVM. A Plan 9 process has nothing like that.
- Its memory model maps a memfd into the guest at fixed addresses, and Plan 9 has no mmap.
- Each Linux syscall would cross four layers: Sentry, a Plan 9 syscall, an h9 exit, and drawterm.

h9's host process already sits where the Sentry would.

**linuxemu's approach, a translator running as a 9front program.** On arm64 and amd64, a Linux syscall doesn't fault; it reaches `syscall.dispatch` as a 9front call with the wrong registers, so there's no note to catch. The translator would also have to build epoll out of helper processes, one per fd, because it can't add readiness to a kernel it doesn't own.

**A Linux microVM beside h9.** It's the simplest way to run Linux, and Linux processes there are complete. But they aren't part of the machine: no shared namespace, no pipes to 9front processes, no 9P mounts in their file tree, and none of h9's sandbox policy. If that's all that's wanted, a microVM is the better tool, and h9 doesn't need this proposal.

**One namespace, two roots, rather than binding the Linux root over `/`.** A bind over `/` in the shared Pgrp would change `/` for 9front processes too, so `rc` would find busybox's tools instead of its own and lose `/bin/rc` itself. A separate Pgrp for Linux processes (`RFNAMEG`) would keep 9front's view intact, but then a mount made by either personality would be invisible to the other, which loses the point. A per-process `slash`, as `chroot` gives, keeps one mount table and two views of it. devlinux's mount points mean the view's binds never need directories to exist in a read-only Linux root.

**`/tmp` and `/mnt/term` shared by path.** A pipeline that writes a file in one personality and reads it in the other needs the path to mean the same thing in both. The cwd lives under `/mnt/term`, so it survives a change of personality.

**uid 0, not 1000.** Alpine's `apk`, Debian's `dpkg` and many install scripts refuse to run as non-root. Linux ids mean nothing to h9's access checks, so being 0 grants nothing beyond what the policy allows. Rootless containers make the same choice.

**Numeric exit statuses.** Linux programs and their callers, shell scripts and build tools, depend on exit codes. Carrying them as decimal strings is what APE already does, so `rc`'s `$status` reads the same either way, and APE's `wait` reads a Linux child's status correctly. The CLI side isn't Linux-specific, so it's [exit-status](0033-exit-status.md).

**Splitting threads and networking out.** Each stage of the original plan was a step toward a different goal: dynamic binaries, then Go, then servers. Threads need cross-vCPU TLB shootdown and per-thread signals; readiness needs host-socket polling and `O_NONBLOCK`. Both are larger and riskier than the rest, and neither is needed to run busybox, Python scripts or compilers. So stages 1 to 3 can be accepted, built and used first. `vfork` stays here, because busybox can't run without it.

**The `stat` and errno mapping, shared with dotl.** [dotl](0022-dotl.md) needs the same mapping for 9P2000.L. Whichever is built first creates it as `src/dotl/attr.zig`, the path dotl names, and the other uses it. Neither depends on the other.

**No vDSO, for now.** Every `clock_gettime` is an exit. A vDSO that reads the counter at EL0 would remove that, but it's an optimisation, and it fixes the clock's layout into guest memory. It's left for later work.

## Compatibility

- **New CLI flag** `--linux-root DIR`, and a new `Machine.Options` field.
- **New device** `#λ`. It's never masked: it serves nothing from the host itself, and what's bound into it is under the policy.
- **Exit codes:** an ELF binary for the wrong architecture is exit 126, like a bad a.out. Numeric statuses come from [exit-status](0033-exit-status.md).
- **vmm interface:** `unmap` takes a length, and `protect` and `hwcaps` are new (see vmm changes). The `none` backend gains stubs.
- **9front processes** see no change unless they exec a Linux binary or use `#λ`.

## Security

- **The guest reaches nothing new on the host.** Every Linux call is served by drawterm's kernel through the same namespace, device mask and policy hooks. The Linux root is under the access rules like the 9front root.
- **`rt_sigreturn`** must sanitize the restored state exactly as `noted` does (see Signals). It gets its own tests, including a forged frame that asks for EL1, or for kernel selectors on amd64.
- **The Linux root's symlinks** are resolved by [symlinks-in-root](0034-symlinks-in-root.md), which never steps above the tree and still checks the resolved path.
- **devlinux's `/proc`** must not reveal host details beyond what the policy already does. `/proc/cpuinfo` and `/proc/meminfo` report the machine's limits (`--cpus`, `--memory`) and the guest-visible features, not the host's. `/proc/<pid>/exe` and the other links show guest paths. `/proc/mounts` doesn't list host paths. Pids are the machine's, so another machine's processes aren't visible, as with devproc.
- **uid 0 inside the Linux root** grants nothing: no h9 check reads Linux ids.
- **New attack surface:** the ELF loader and the VMA layer turn guest-supplied sizes and offsets into host mappings. Both validate against the address-space limits before mapping, as the a.out loader does, and the vmm's range `unmap` and `protect` refuse ranges outside the user half. Lazy faults allocate only inside VMAs, and count against `--memory`.

## Done when

Integration cases tagged `[linux-personality]`. The fixtures are static and dynamic musl binaries and an Alpine minirootfs, fetched by `scripts/fetch.sh` at a pinned release.

1. **Static binaries:** `h9 ./hello-musl` prints hello on HVF and on the emulator, for arm64, and for amd64 on the emulator.
2. **busybox:** `h9 --linux-root alpine sh -c 'ls / | wc -l'` runs busybox's shell, which uses `vfork`. A mixed pipeline works both ways: `h9 --linux-root alpine sh -c '/9/bin/ls /9/bin | wc -l'` and `h9 --linux-root alpine --rc "ls /bin | '#λ/bin/busybox' wc -l"`.
3. **Dynamic binaries:** Alpine's dynamically linked tools (`apk --version`, `python3 -c 'print(1)'`) run.

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

## Implementation

1. A personality on the process record, the dispatch switch in `Machine.loop`, the ELF loader, the stack and auxv, `Backend.hwcaps`. Static musl hello, on arm64 and then amd64.
2. File, process and terminal calls; the errno and `stat` mapping; exit statuses; `wait4`; `vfork`; signals for the common notes; devlinux and the Linux view; `--linux-root`. busybox and the mixed pipelines. Needs [symlinks-in-root](0034-symlinks-in-root.md).
3. The vmm range `unmap` and `protect`, sorted regions and the emulator's incremental sync; the VMA layer with lazy pages; `PT_INTERP`. Dynamic binaries.
4. DESIGN.md gets a "Linux personality" section.

## Open issues

- **Job control.** Stopping a process for `SIGTSTP` and resuming it needs a stopped state in h9's process model, which 9front doesn't have either. Until then, `Ctrl-Z` in busybox's shell does nothing.
- **Shared file mappings.** Some programs (SQLite in WAL mode, LMDB) map files shared and writable, and fail here with `ENODEV`. A write-back path through the kernel at `msync` and `munmap` might be enough for them.
- **ptrace, Linux namespaces, cgroups, io_uring, bpf and `/sys`** are out of scope. Is anything common blocked by their absence that should be stubbed?
