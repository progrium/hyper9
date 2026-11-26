# The Linux ABI

This describes, as built, the Linux ABI: how Linux ELF binaries are loaded and run beside 9front ones in the same machine. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Linux ABI](#linux-abi)
  - [Loading](#loading)
  - [Memory](#memory)
  - [Files for databases](#files-for-databases)
  - [Syscalls](#syscalls)
  - [Signals](#signals)
  - [The Linux view](#the-linux-view)
  - [Roots, environment, and console](#roots-environment-and-console)
  - [Sockets and readiness](#sockets-and-readiness)
  - [Threads](#threads)
  - [IPC for PostgreSQL](#ipc-for-postgresql)
  - [Named pipes](#named-pipes)
  - [32-bit x86](#32-bit-x86)
  - [Not yet](#not-yet)
  - [Tests](#tests)

## Linux ABI

Linux ELF binaries run next to 9front ones in the same machine ([linux-personality](../design/epoch-0/linux-personality.md)). The ABI is picked at exec by the binary's format: `exec` of an ELF builds a Linux image, and a Linux `execve` of an a.out goes back to 9front. A Linux process keeps the same kernel `Proc`, fds, pipes, notes and namespace; only its syscall table and root differ.

### Loading

`src/abi/linux/elf.zig` and `src/abi/linux/exec.zig` load static and dynamic ELF for arm64 and amd64. ET_DYN programs load at a fixed PIE base and `PT_INTERP` (musl's `ld-musl`, read in the Linux view) at the first free range.

A segment's whole file pages are a lazily filled private file mapping (`Vma.src`, see Memory) of the file exec read, opened again and checked against what was read, so a page counts against `--memory` only once it's touched. A page two segments share and a segment's last file page, whose bytes past `p_filesz` start the bss, are copied in at exec, as is the whole image when the file can't be opened again (a program loaded from a host path). exec still reads the whole file to check it. It opens a program's file again where exec found it, in the current view and then the Linux view, and the interpreter's in the Linux view, where it was read. `/proc/n/maps` shows a segment as one line, though its copied and lazy parts are VMAs of their own, and names the interpreter by its path.

While a process maps a program's file this way, the file is busy, as on Linux: a Linux `open` of it for writing, which is tried without `O_TRUNC` first, and a `truncate` of it by path, fail with `ETXTBSY` (`busy` in `src/abi/linux/sys.zig`, by the file's lock key), until the last process mapping it execs or exits. A rename over it is fine, since the image keeps the old file. An fd opened for writing before the exec, and 9front programs, aren't refused. The interpreter isn't kept busy, as Linux lets it go after exec.

The stack carries argv, envp and auxv, with `AT_HWCAP` limited to what every engine has.

arm64 gets a one-page vDSO holding `__kernel_rt_sigreturn`, with the `LINUX_2.6.39` version tables Go's vDSO lookup needs.

amd64 gets a vDSO with `__vdso_clock_gettime`, `__vdso_gettimeofday`, and `__vdso_time` (version `LINUX_2.6`, which glibc, musl, and Go look up), on engines whose guest `rdtsc` reads the host's own count (`engine.Engine.hostTsc`: native, and KVM on x86, which zeroes each vCPU's TSC offset when the kernel has `KVM_VCPU_TSC_OFFSET`) and on hosts whose count is invariant; elsewhere it gets none, as the emulators' `rdtsc` counts instructions (`src/abi/linux/vclock.zig`). The page before it is the clock page, read-only, one per engine and mapped into every program (`[vvar]` in `/proc/n/maps`): a line through the time stamp count, monotonic ns = `mono_base` + (count − `tsc_base`) × `mult` / 2³², with real time `real_off` ahead of it, under a sequence count the functions retry on. They cover the realtime and monotonic clocks `clock_gettime` serves and make the syscall for the rest, and until the first fit. h9 fits the line on Linux syscalls, every half second: the rate is measured over all the time since the first sample, each fit starts where the line is, so it never goes back, and slews toward the host's monotonic clock at most 500 ppm, stepping forward only when the host's is more than 1 ms ahead. The Linux layer's own clock calls read the same line, so the vDSO and syscalls agree.
### Memory

The kernel's `Mm` (`src/kern/mm.zig`, shared with 9front processes; see Kernel, Memory) keeps VMAs over the engine's regions, with lazy anonymous pages faulted in on first touch, a 64 KiB chunk at a time (a multiple of every host's page size), `mmap`/`munmap`/`mprotect`/`mremap`, private file mappings filled from the file chunk by chunk on first touch (`Vma.src`), and shared mappings; `src/abi/linux/mm.zig` adds Linux's layout, `mmap`'s protection bits, and `brk`. A fault reads a new chunk's file pages with the Mm's lock dropped, so a slow read doesn't stall the process's other threads, and adds the chunk only if no one else did meanwhile and its lazy VMAs are unchanged. A fill that finds the file's end, or a failed read, sets the VMA's `eof`: its pages wholly past it stay unmapped, and touching one is `SIGBUS` (`BUS_ADRERR`) for the guest and `EFAULT` for a syscall's buffer, as on Linux, while the bytes past the end in the last page read as zero. `madvise(MADV_DONTNEED)` frees the private chunks it covers whole, so their memory goes back to the engine, and zeroes the rest; a chunk a fork shares copy-on-write that it covers whole only drops this process's reference, and one it covers in part is copied first.

A private mapping of a file that's also mapped shared is the exception: it maps the shared pages copy-on-write (`Vma.cow`), so it sees the file's changes until it writes a page, as on Linux; Wine reads wineserver's session memory through one.

A shared mapping gets chunks of its own, the rest of them padded with VMAs the guest doesn't see, so no other mapping shares their pages.

A shared file mapping sits at its file offset's place in a chunk, and its pages come from a table of the files mapped shared (`src/abi/linux/shmfile.zig`), one set per chunk of the file, for every Mm of every machine on the same engine: read from the file at the first mapping, kept coherent with the Linux layer's `read` and `write` of that file, and written back by path when the last mapping goes if any could write.

A chunk that one lazily filled private file mapping covers whole, where the file offset and the address agree modulo the chunk size, maps the file's shared pages for that chunk from a page cache (`src/abi/linux/pagecache.zig`) instead of a copy of its own: every process mapping it, a running program's segments and `mmap`'s private file mappings alike, maps the same pages copy-on-write (`Chunk.cow`, as after `fork`), so a write copies the chunk first and never reaches the shared pages or the file, and the pages count once against `--memory`. They're read from the file at the first touch by any process and go when the last mapping of them does. The cache knows a file by its identity and a stamp of its qid version, modification time, and length taken at `mmap` or `exec`, so a file that changed since gets new pages; a write or truncate through the Linux layer drops the file's chunks for mappings made after it, while earlier mappings keep the ones they share. A private file mapping of a chunk or more is placed at its offset's place in a chunk, as a shared one is. arm64's linkers align segments to 64 KiB, so arm64 programs share all but the chunks where segments meet; x86_64 programs, aligned to 4 KiB, mostly don't ([cow-fork](../design/epoch-0/cow-fork.md)).

`fork` shares a shared mapping's chunks, making the ones no one has touched yet first, and shares every other touched chunk copy-on-write ([cow-fork](../design/epoch-0/cow-fork.md)): both processes hold its pages (`Pages`, reference counted), mapped without write in both, and the parent's are shot down on its other threads' vCPUs before `fork` returns. The first write to such a chunk by either side, from the guest (a write fault) or from the host on its behalf (a syscall's buffer, `copy`, `hostSlice`, a pinned `read`, `hostEach`, an unmap, or `MADV_DONTNEED` of part of it), copies the chunk, less its zero pages, or, if the other side has written or exited already, keeps it and maps it writable again (`Mm.own`). The old pages' reference is dropped only after a shootdown, so the other side can't take them for its own while this one's vCPUs still read them. A copy that finds no memory is a first touch past `--memory`: `SIGKILL` for a guest write, `EFAULT` for a syscall's buffer, `ENOMEM` for `madvise`. A chunk with overlays, or one a pin holds for a blocking `read` into it, is copied at `fork`. Chunks no one has touched yet aren't copied: a lazily filled file mapping's child takes a reference on its file and fills them itself. `VmRSS` counts a shared chunk in each process, as Linux counts shared pages, and `--memory` counts its pages once. `vfork` shares the address space and parks the parent until the child execs or exits.
### Files for databases

`fcntl` record locks (POSIX, owned by the process and dropped when it closes any fd of the file or ends, and OFD, owned by the Chan) and `flock` locks are kept in one table for the h9 process (`src/abi/linux/locks.zig`), keyed by the file's device, instance and qid path; `F_SETLKW` and blocking `flock` poll every 2 ms and a signal ends them.

`fsync` and `fdatasync` are a wstat that changes nothing, which `#U` serves with the host's `fsync` of the open file or directory (`fcntl(F_FULLFSYNC)` first on macOS, which also flushes the drive's cache; `FlushFileBuffers` on Windows, where a directory has nothing to sync). `syncfs` is the host's `syncfs` on the fd's `#U` file system (on macOS, `sync` and then the fd's own `F_FULLFSYNC`), and `sync` is the host's `sync`. A `write`, `pwrite64`, `writev`, `pwritev`, or `sendfile` through an fd opened with `O_DSYNC` or `O_SYNC` is followed by that `fsync` before it returns, and a failed sync fails the write; `F_GETFL` reports the flag, and `F_SETFL` leaves it as `open` set it, as on Linux.

`fallocate` mode 0 grows the file with a truncate up, `FALLOC_FL_KEEP_SIZE` does nothing, and the hole modes are `EOPNOTSUPP`.

A `pread64` of 16 KiB or less reads 128 KiB ahead into a cache per fd, trusted until any Linux write or truncate, any lock change, or a second.

`wait4`, `waitid` and `getrusage` report CPU time from the host thread a guest thread runs on (`src/abi/linux/cputime.zig`); a group's leader puts it, with its reaped children's, in its wait record's user and system times (a hook in `src/kern/proc.zig`).
### Syscalls

`src/abi/linux/sys.zig` and `src/abi/linux/nr.zig` have one table, decoded per architecture (amd64's older forms such as `open` and `stat` map onto the `*at` calls), translated onto the drawterm kernel. Errors map from 9front error strings to errno.

A Linux process starts as uid and gid 0 and keeps real, effective and saved ids and up to 32 supplementary groups, which the `set*id` calls and `setgroups` change as Linux's do for root and for other users, so `su` and programs that refuse to run as root (PostgreSQL's `initdb`) work; `stat` reports every file as owned by the caller's effective uid and gid, and permission checks stay with the namespace and the sandbox.

`link`, `rename`, `readlink`, `symlink`, and the `stat` calls use the kernel's optional device operations ([file-interface](../design/file-interface.md), and [spec/kernel.md](kernel.md)), through `src/kern.zig`'s `link`, `rename`, `readlink`, `symlink`, `getattr`, and `fgetattr`. `link` is a hard link where the device makes one, a host tree's `linkat` or a 9P2000.L server's `Tlink`, so the two names are one file with `st_nlink` 2; elsewhere, an overlay or a 9P2000 mount, it copies the file with an exclusive create. `rename` is one move where the device has it, replacing a file at the new name: the host's `rename(2)` within one host tree, a move in memory within one overlay (`h9_overlay_move`), and `Trename` on a 9P2000.L mount; across directories elsewhere it's `EXDEV`, as it is for a directory still in an overlay's lower tree, between two trees, and on Windows hosts. `stat`, `fstat`, `fstatat`, and `statx` take the link count, ctime, and nanosecond times from `getattr` where the device says them (a host tree, an overlay over one, a 9P2000.L mount), with the rest from the `Dir` as before: the owner is still the caller's.

`arch_prctl(ARCH_SET_GS)` and `ARCH_GET_GS` set and read the GS base, as `ARCH_SET_FS` does FS (`X86Extra.gs`). On arm64, an EL0 `mrs` of an ID register (`MIDR_EL1`, the `ID_AA64` registers), which Linux traps and emulates, is emulated on the hypervisors with values that match `AT_HWCAP` (`src/abi/linux/exec.zig`); the emulator's CPU answers for itself.

`symlink` makes a link in memory in an overlay (an `Nlink` node in `src/kern/dev/overlay.zig`), a host symlink in a `#U` tree, the new name checked like a create, or a server's link by `Tsymlink` on a 9P2000.L mount, plain or under a mount index (each the device's `symlink`); elsewhere, such as a 9P2000 mount, it's `EPERM`, as it is on Windows hosts. A Linux process's links are followed by the kernel's walk from its root, the Linux view ([linux-symlinks](../design/epoch-0/linux-symlinks.md), and [Linux symlinks](sandbox.md#linux-symlinks) in the sandbox's spec): an absolute target names the guest's path, whatever tree the link is in, so a link into another `#L` layer, mount, or bind resolves, and a host path the guest doesn't see is `ENOENT`. `lstat`, `fstatat` and `statx` with `AT_SYMLINK_NOFOLLOW`, `readlink`, `rename`, and `unlink` act on the link, and `O_NOFOLLOW` (without `O_PATH`) is `ELOOP` on one; a loop of links is `ELOOP`. A link's `Dir` has `H9_DMSYMLINK`, so `stat` and `getdents` give `S_IFLNK` and `DT_LNK`, and a dangling link lists and removes. `/proc/self/exe`, `/proc/self/cwd`, and `/proc/self/fd/N` are the Linux layer's (`procLink`): `readlink` and `lstat` give their targets, and an open of `/proc/self/fd/N` is a dup of the fd (`#d/N`), as `/dev/fd/N`'s is, so a deleted file's or a pipe's still opens.

A Linux parent gets `SIGCHLD` when a child leaves a wait record (a hook in `src/kern/proc.zig`), unless it ignores it. Interrupted calls restart or return `EINTR` per `SA_RESTART`, and the waits (`pause`, `poll`, `nanosleep` and the like) always return `EINTR`.
### Signals

Notes are signals (`src/abi/linux/signal.zig`). `interrupt`, `hangup` and `alarm` map to `SIGINT`, `SIGHUP` and `SIGALRM`; faults to `SIGSEGV`, `SIGBUS`, `SIGILL` or `SIGFPE` with `si_addr`, an x86 CPU exception other than a page fault by its vector as Linux's `traps.c` does (`x86Exception`: `#UD` is `SIGILL`, `#DE` `SIGFPE`, `#AC` `SIGBUS`, and the rest `SIGSEGV`), and an arm64 one by its exception class (`a64Exception`: an undefined, SVE, or SME instruction is `SIGILL`, and a misaligned PC or SP `SIGBUS`); a closed pipe to `SIGPIPE`; and Linux `kill` posts `linux: signal N`, so a 9front process sees a note it can print.

Handlers get the kernel's frame layout on both architectures, and `rt_sigreturn` restores only what user code may set: NZCV on arm64, and on amd64 the user flags with `cs` and `ss` kept and a canonical `rip`. A note with no signal kills a Linux process. A process killed by a signal exits as the host would report it, 128 + N.
### The Linux view

A Linux process's `/` is `#L` (`src/kern/dev/linux.zig`; `#λ` is an alias in namespace files), a small tree of mount points (`/9`, `/tmp`, `/mnt/term`, `/dev`, `/proc`, `/sys`) with the Linux tree's stack, `#Olinux`, unioned after it ([mounts](../design/epoch-0/mounts.md)): the mounts on `#L` and under it, such as `--dir ./alpine:#L`, merged at every depth. `/9` is the machine's 9front root when there is one, and `/tmp` and `/mnt/term` are the 9front ones, so files pass between the two by the same names.

`/dev` serves `null`, `zero`, `full`, `random`, `urandom`, the console as `tty`, and `fd`, and `/dev/shm` is an ephemeral overlay of its own.

`/proc` and `/sys` serve the files libc, busybox, Python and htop read (`self`, `cpuinfo`, `meminfo`, `stat`, `uptime`, `mounts`, per-process `maps`, `stat`, `statm`, `status`, `cmdline`, `exe`, `fd` and `task`), with `cpuinfo` following `--cpus`; only a thread group's leader is listed in `/proc`, and its other threads are under its `task`.

A process's dot is renamed when it changes views. drawterm's `namec` doesn't cross mounts on a `#` path, so `#L` is exempted (`src/kern/chan.zig`).

`chroot(2)` ([linux-chroot](../design/epoch-0/linux-chroot.md)) narrows a process's Linux root to a directory it walks to as any Linux path: `h9_linux_chroot` (`src/kern/linux.zig`) keeps the directory in the process's record (`Proc.lroot`), its `Chan` marked `CLROOT` so `h9_linux_inview` counts it as the Linux view, and makes it `up->slash`. Absolute paths, absolute link targets, and exec's program and interpreter are then found from it, and `..` at it stays there (`h9_fs_atroot`, from `walkl` in `src/kern/chan.zig`). A chroot to `#L`'s own top clears it. `h9_linux_setslash` returns to `lroot` rather than `#L`, so a stay in the 9front view (exec, a socket's open) keeps it, forks inherit it, and `h9_kern_release` closes it. The working directory isn't moved; under the new root, it's renamed by a walk from there, so `getcwd` names it from the new root. A directory fd's path from before the chroot is walked from `#L`'s top when the chroot's walk doesn't reach the same directory (`h9_linux_dotfd`), so `fchdir` and `*at` calls with it work, and lead out to the Linux view's top at most. `/proc` and `/dev` are mounted on `#L`'s directories, so a chroot has them only if its tree does. `mount`, `umount2`, `pivot_root`, `unshare`, and `setns` are `EPERM`.
### Roots, environment, and console

A Linux tree is whatever is mounted on `#L`; trees aren't told apart by their contents. With one, a bare program name is looked up on the Linux `PATH`; `--rc` still runs 9front's rc. A 9front process runs a Linux program by its `#L` path.

The environment goes both ways: a Linux program gets `/env` as `NAME=value` (with `USER`, `LOGNAME`, `HOME` and a default `PATH`), and a 9front program exec'd from Linux gets `envp` written to `/env`.

`isatty` is true only when h9's own stdin and stdout are terminals. The console's termios is one per machine: `TCSETS` sets raw mode from `ICANON`, and, through the optional `echo` and `crnl` on `Machine.Stdio.raw`, the host's echo from `ECHO` and its CR-to-NL mapping from `ICRNL`; `TIOCGWINSZ` is the host terminal's size, through the hook's optional `size`, or 80x24. In non-canonical mode with `VMIN` 0, a console read waits at most `VTIME` tenths of a second and may return 0 bytes. consctl also takes `echooff` and `echoon`, which keep the line discipline.

Pseudoterminals ([linux-pty](../design/epoch-0/linux-pty.md)) are `#τ` pairs: the Linux view binds `#τ` on `/dev/pts` and `#τ/ptmx` on `/dev/ptmx`, and `stat` gives them Linux's device numbers (5,2 for `ptmx` and every master, 136,N for slave N). Each open of `ptmx` makes a pair, numbered from 0 per machine, and returns its master; `#τ/N` is pair N's slave, which opens while the master is open and `TIOCSPTLCK` has unlocked it. The pair keeps the termios, window size, foreground group, session, and lock, which the ioctls on either side read and set: `TIOCGPTN`, `TIOCSPTLCK`, `TIOCGPTPEER`, the termios and termios2 calls, `TIOCGWINSZ` and `TIOCSWINSZ` (which sends `SIGWINCH` to the foreground group), `TIOCSCTTY`, `TIOCNOTTY`, `TIOCGPGRP`, `TIOCSPGRP`, `TIOCGSID`, `FIONREAD`, `TIOCOUTQ`, and `TCFLSH`. A session leader that `setsid` made takes a slave it opens without `O_NOCTTY` as its controlling terminal; the machine's first process keeps the console. `/dev/tty` opens the session's pty when it has one, and the console otherwise, and `/proc/self/fd/N` names a pty's side as `/dev/pts/N` or `/dev/ptmx`.

The pair's termios is applied as Linux's `N_TTY` does, in `src/kern/dev/pty.zig`: input written to the master goes through `ISTRIP`, `IGNCR`, `ICRNL`, and `INLCR`; with `ISIG`, `VINTR`, `VQUIT`, and `VSUSP` send `SIGINT`, `SIGQUIT`, and `SIGTSTP` to the foreground group (from the writing process) and, without `NOFLSH`, drop the pending input; with `ICANON`, `VERASE`, `VWERASE`, `VKILL`, and `VEOF` edit a line of up to 4096 bytes, which the slave reads whole, at most a line a read, when it ends at a newline, `VEOL`, `VEOL2`, or `VEOF` (on an empty line, an end of file). Echo follows `ECHO`, `ECHOE`, `ECHOK`, `ECHOKE`, `ECHONL`, and `ECHOCTL`, and the slave's output and echo go through `OPOST` with `ONLCR` and `OCRNL`. Without `ICANON` a slave read with `VMIN` 0 waits at most `VTIME` tenths of a second, as the console's does. Each direction queues 64 KiB; echo and finished lines are dropped when the slave's queue is full, as `N_TTY` drops input, and other writes wait for room. Until the slave first opens a master read waits; once the slave has closed, the master reads what's left and then `EIO`. The master's last close hangs the slave up (reads end, writes are `EIO`), ends its session's terminal, and sends `SIGHUP` to the foreground group.
### Sockets and readiness

A socket ([linux-net](../design/epoch-0/linux-net.md)) is a `/net` conversation, its fd the conversation's data file. `socket(2)` opens `/net/tcp/clone` or `/net/udp/clone` in the process's namespace, in the 9front view, as `dial(2)` does, so it's devip's (`#I`) unless something else is mounted on `/net`. With devip's, `--net` and the policy's devip hooks apply as they do to 9front programs (a socket under `--net=disable` is `EACCES`).

A conversation from a mounted `/net`, such as another h9's served with `--serve-net`, is devmnt's, which can't say whether a read would block, so `src/kern/rconv.zig` attaches it to a read-ahead: a kproc reads its data into a 64 KiB ring (UDP keeps each message's length), and `recv`, `MSG_PEEK`, a plain `read`, and readiness answer from the ring. A non-blocking connect writes `connect` to its `ctl` in a kproc, writable when done, with `SO_ERROR` from its error. A listening one has a kproc that opens `listen`, which waits in the server, and keeps one call for `accept`, readable while it waits. Sends write the data file. The description's last close writes `shutdown rdwr` (or 9front's `hangup`) and lets the conversation go. The serving machine's policy governs what its conversations reach.

`connect`, `bind` and `listen` write control messages; devip gains `nbconnect` (a connect the host finishes in the background, writable when done, with `SO_ERROR` from the host socket), `shutdown`, `sockopt`, a socket for an announce on port 0, no `listen` for UDP, and 4096 TCP and 1024 UDP conversations.

`recvfrom`, `sendto` and their flags go straight to the host socket, with the policy's connect check on a `sendto` address; an unbound UDP socket's first `sendto` connects it, since a bind is refused under the default policy, and a UDP bind to any address and port 0 that the policy refuses leaves the socket unbound for its `connect` or `sendto` to bind.

DNS is the Linux program's own: when the Linux root has no `/etc/resolv.conf`, the machine binds `#Letc` (devlinux's attach for files a root may lack) after the root's `/etc`, which is bound over itself first with `MCREATE` so files made in `/etc` go to the root, and its `resolv.conf` names the host's DNS servers, read by the CLI from the host's `/etc/resolv.conf`, or on Windows the IPv4 servers `GetNetworkParams` lists (Google's public servers where they name none).

Without name patterns, port 53 on those servers is allowed even when they're link-local, as a cloud VM's resolver is, and `--print` says so in a caveat; `--net-allow` address patterns must cover them. With a name pattern, the machine answers DNS itself ([linux-dns](../design/linux-dns.md), and [The machine's resolver](sandbox.md#the-machines-resolver) in the sandbox's spec): every connect or `sendto` to port 53, to whatever server the program names (the host's from `#Letc`, or a root's own), goes to the machine's resolver on the host's loopback, which refuses names no pattern covers and records the addresses it answers with, so a program's lookup of an allowed name leads to an allowed connect. The socket is otherwise a host socket, as any other is, and a `recvfrom` or `getpeername` on it gives the server the program asked.

getaddrinfo ranks its answers by connecting a UDP socket to each address, which sends nothing, and reading its source address, so under name patterns a UDP `connect` to an address recorded for an allowed name, on any port, is made on the host as a probe ([Route probes](sandbox.md#route-probes) in the sandbox's spec): it succeeds, or fails with the host's error, such as `ENETUNREACH` for an IPv6 address on a host with no IPv6 route, and `getsockname` gives the host's source address, so the program ranks a reachable IPv4 address first, as it would with the network open. Unless a pattern allows UDP to that address and port, the socket is probe-only: `send`, `sendto`, `sendmsg`, and `write` on it fail with `EACCES`. An unconnected socket's first `sendto` connects it, so when that `sendto` fails with `EACCES` the socket is left unconnected, and its next `sendto` connects again.

`socketpair` is a 9front pipe, and a named or abstract `AF_UNIX` socket is a pipe end too, connected through `#s`: a listener posts its pipe's write end under the bound file's identity, and a connect posts its connection's pipe end and writes that post's name to the listener, for `accept` to open.

A listening socket's bound file `stat`s as `S_IFSOCK`. `sendmsg` and `recvmsg` carry `SCM_RIGHTS`, posting each fd in `#s` and recording the batch against the receiving pipe end, so fds pass between the processes of one machine.

`AF_NETLINK` with `NETLINK_ROUTE` answers the link and address dumps (`RTM_GETLINK`, `RTM_GETADDR`) from the host's interfaces (`src/abi/linux/netlink.zig`), which `getifaddrs` and Go's `net.Interfaces` make. `recvmmsg` and `sendmmsg` loop over the single-message calls, and `IPV6_V6ONLY` is passed to the host socket, so an IPv4 and an IPv6 wildcard listener can share a port.

Readiness is kernel code (`src/kern/linuxnet.zig`): `h9_poll` asks each fd's channel whether it would block (qio queues, the console, host sockets with a zero-timeout `poll`; files and 9P are always ready) and sleeps on a wake generation that qio's wakeups (a hook in `src/kern/qio.zig`), the console reader and a host-socket watcher thread bump.

`poll`, `ppoll`, `select` and `pselect6` use it, `epoll` keeps interest lists in the Linux layer (edge-triggered by generation), and `#ε` serves eventfd and epoll instances. `O_NONBLOCK` asks first and returns `EAGAIN`, and a blocking socket read waits in `h9_poll` so a signal can interrupt it. A Linux pipe read takes everything queued.
### Threads

A thread ([linux-threads](../design/epoch-0/linux-threads.md)) is its own kernel process, with its own `Proc`, vCPU lease and note queue, forked with `RFNOWAIT` (and `RFFDG` unless `CLONE_FILES`), sharing the creator's `Mm` and a thread group (`lsys.Group`), which holds the tgid, the members, the signal actions, fd flags, directory buffers, sockets and epoll sets.

`getpid` is the tgid, `gettid` the process's own pid. A thread's forks are the leader's children (`RFLXTHREAD` in `src/kern/proc.zig`), so any thread can wait for them, several at once, and `waitid` takes `WNOWAIT`.

`clone` takes the flag sets glibc, musl and Go use (`CLONE_SETTLS`, `PARENT_SETTID`, `CHILD_CLEARTID`); others are `EINVAL`.

Futexes (`WAIT`, `WAIT_BITSET`, `WAKE`, `WAKE_BITSET`, `REQUEUE`, `CMP_REQUEUE`) are kernel wait queues in `src/kern/linux.zig`, keyed by the `Mm` and address, or in a `MAP_SHARED` mapping (unless `FUTEX_PRIVATE_FLAG`) by its chunk's pages and the offset in them, so processes sharing the pages meet there, with interruptible waits; `WAKE_OP` and PI futexes are `ENOSYS`.

A thread's exit runs its robust list and clears and wakes its `clear_child_tid`. `exit_group`, or a fatal signal, kills the other members and the leader waits for them before the group's status is reported. `execve` from a non-leader kills the others and hands the exec to the leader.

`tgkill` and `tkill` reach one thread; a process-directed signal blocked by the leader goes to a member that doesn't block it.

Memory calls are serialised per `Mm`, and an unmap or protect that narrows access while other threads share the `Mm` frees its pages only after `AddressSpace.shootdown`; a layout change then leaves the other runs of the chunks it touches mapped as they were, and maps new pages as runs of their own, so no other thread's live page is ever briefly unmapped (on a hypervisor that faulted or failed its syscalls with `EFAULT`).

`/proc/<pid>/status` shows `Tgid` and `Threads`. Not yet: sharing `CLONE_FS`, and shared futexes across `fork` (they key on the `Mm`).
### IPC for PostgreSQL

System V shared memory (`src/abi/linux/sysvshm.zig`): `shmget`, `shmat`, `shmdt` and `shmctl`, a segment being chunk pages held by a table per engine and by each address space that attaches it, its attach count those pages' references, and a removed one freed with its last detach; semaphores are none, as musl's process-shared POSIX ones are futexes.

`signalfd` is an `#ε` eventfd the process model writes when a signal the fd's mask names is left pending, and a read takes the signals as `signalfd_siginfo`.

`setitimer`'s `ITIMER_REAL` and `alarm` are served by one kernel process (`src/abi/linux/itimer.zig`) that posts `alarm` to a due process through a reference to its kernel record (`h9_kern_selfref`), waking at least every 5 ms while any timer is set and ending two seconds after the last is cleared; the CPU-time timers are accepted and never fire. `sync_file_range` is a no-op, since `fsync` does the writing.
### Named pipes

`mkfifo` and `mknod(S_IFIFO)` make a FIFO file that stays in the file system ([linux-fifo](../design/epoch-0/linux-fifo.md)): an overlay node in overlays, a host FIFO on a host tree, and a `Tmknod` on a 9P2000.L root, with `EPERM` anywhere else. A FIFO's `Dir` carries `H9_DMFIFO` (9P2000.u's `DMNAMEDPIPE`, `0x00200000`), so `stat`, `lstat`, `fstat`, and `getdents` report `S_IFIFO` and `DT_FIFO`. `mknod` of a regular file makes one, and devices and sockets are `EPERM`.

A Linux open of a FIFO (but not `O_PATH`) joins a pipe kept for that file in one table for the h9 process (`src/kern/fifo.zig`), keyed by the file's device, instance, and qid path, with a host file's key leaving out devfs's attach number, so the machines of one h9 process that open one host FIFO share its pipe. The pipe is devpipe's, in FIFO mode: one queue that every open reads and writes, so read, write, poll, and fstat are a pipe's. The entry goes once nothing has the pipe open, and a later open starts afresh.

The open rules are Linux's: `O_RDONLY` waits for a writer and `O_WRONLY` for a reader, and a signal interrupts the wait with `EINTR`. With `O_NONBLOCK`, a read open returns at once and a write open with no reader is `ENXIO`. `O_RDWR` returns at once, as both ends. A read with no writer left is EOF, and a write with no reader left is `EPIPE` and `SIGPIPE`.

### 32-bit x86

With `--arch 386` (the web host's only architecture), i386 ELF32 programs run on the emulator ([linux-i386](../design/epoch-0/linux-i386.md)). The address space tops out at `0xC0000000`, with PIEs at `0x400000`.

Calls come through `int 0x80` and the i386 table; `ia32.serve` in `sys.zig` joins split 64-bit arguments, maps the `*_time64` calls and the `*32`/`*64` forms onto the generic calls, and serves the multiplexers (`socketcall`, `ipc`) and the old forms (`old_mmap`, `old_select`, the 64-byte `stat`), while the generic calls read `long`s, pointers, `iovec`s, `msghdr`s, `rusage`, and `siginfo` at the process's word size.

TLS is `set_thread_area`'s GDT entry 6 (selector `0x33`), whose base is the vCPU's `X86Extra.tls`, which h86's selector table holds ([h86](h86.md)).

Signals use i386's `rt_sigframe` and old `sigframe`; `sigreturn` keeps `%gs` only if it's the TLS selector.

The 386 fixtures and Go's `linux/386` builds go in `fixtures/linux/386`, and `-Darch=386` runs the Linux cases with them on the emulator.
### Not yet

Job-control stops (`SIGSTOP` and `SIGTSTP` are ignored for now), and the engine's range `unmap` and `protect`.

### Tests

The `[18]` integration cases run static musl programs from `tests/fixtures/linux` (built by `zig build linux-fixtures`) and busybox from an Alpine root that `scripts/fetch.sh` pins by digest into `.local/linux/alpine-<arch>`.
