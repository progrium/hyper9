---
id: 105
slug: linux-i386
title: 32-bit x86 Linux programs
status: implemented
created: 2026-11-08
authors: [progrium]
depends: [linux-personality, linux-threads, linux-net, browser-host]
areas: [linux, vmm, web]
branch: [main]
---

# Proposal: 32-bit x86 Linux programs

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

The [Linux personality](linux-personality.md) runs 32-bit x86 (i386) Linux programs as well as arm64 and amd64 ones: ELF32 loading, the `int 0x80` syscall ABI with its numbering and 32-bit struct layouts, i386 signal frames, and TLS through `set_thread_area`. They run on the emulator on every host and on v86 in the [browser host](browser-host.md), which only runs 386 code. So the browser build can run real Linux programs, such as Alpine's x86 busybox, apk, and Go's `linux/386` binaries, for the Linux personality's page.

## Background

The Linux personality loads ELF64 programs for the machine's architecture and serves the generic syscall ABI that arm64 and amd64 share, with amd64's older calls. `src/linux/elf.zig` turns away 32-bit ELFs. The browser host's only backend is v86, a 386 CPU, so no Linux program runs in the browser today. The emulator already runs 9front's 386 binaries, and v86 does in the browser.

i386 Linux differs from the 64-bit ABIs in ways that reach most of the syscall layer:

- **Entry.** `int 0x80`, with the number in `eax`, arguments in `ebx`, `ecx`, `edx`, `esi`, `edi`, and `ebp`, and the result in `eax`. musl uses `int 0x80` when the auxv has no `AT_SYSINFO`, and Go always does.
- **Numbering.** Its own table (`arch/x86/entry/syscalls/syscall_32.tbl`), with old calls kept under their first numbers: `select` is the old one-argument form and `_newselect` the current, `mmap` takes a block in memory and `mmap2` takes a page offset, the `stat` family has old 32-bit forms and `*64` forms, and the uid/gid calls have 16-bit forms and `*32` forms.
- **64-bit arguments** (`pread64`, `ftruncate64`, `fallocate`, `fadvise64_64`, `_llseek`) come in two registers, low half first.
- **time64.** musl on 32-bit uses the `*_time64` calls (`clock_gettime64`, `futex_time64`, `ppoll_time64`, and so on), which take 64-bit `timespec`s, falling back to the 32-bit calls only on `ENOSYS`.
- **Struct layouts.** `long` and pointers are 4 bytes: `iovec`, `msghdr`, `cmsghdr`, `sigaction`, `stack_t`, `siginfo`, `rusage`, `sysinfo`, `timeval`, `itimerval`, `rlimit` (from `getrlimit`), `robust_list_head`, `epoll_event` (packed, as on amd64), and `user_desc`. `stat64` is 96 bytes and the old `stat` 64; `statfs64` is 84 bytes; `flock64` is packed.
- **Multiplexers.** `socketcall` and `ipc` carry the socket and SysV calls, with their arguments in memory. musl uses the direct socket calls (since Linux 4.3) but falls back to `socketcall`; older binaries use it only.
- **TLS.** There's no thread pointer register. A program asks for a GDT entry with `set_thread_area` (entry -1 picks one; Linux's is 6, selector `0x33`), loads `%gs` with it, and reads `%gs:0`. `clone` with `CLONE_SETTLS` takes a `user_desc`.
- **Signal frames.** `rt_sigframe` (return address, `signo`, pointers to `siginfo` and `ucontext`, the `siginfo`, the `ucontext` with a 32-bit `sigcontext` and an `fpstate` with an FXSAVE image, then the `retcode` trampoline), returned through `rt_sigreturn` (173). Handlers without `SA_SIGINFO` get the old `sigframe`, returned through `sigreturn` (119); musl's `__restore` uses it.

## Proposal

### Machine

A Linux program's architecture is the machine's (`--arch 386`, as for 9front's 386 binaries; the browser host's default). `elf.check` accepts `EM_386` ELF32 files when the machine is 386, and widens their headers to the ELF64 shapes the loader uses. The auxv, `argv`, and `envp` are 4-byte words, `AT_PLATFORM` is `i686`, `AT_HWCAP` is CPUID 1's `edx`, and there's no `AT_SYSINFO`, so musl and Go use `int 0x80`.

Address space layout follows the architecture: `mm.Layout.of(arch)` gives the top of user space (`0xC0000000` on 386, as Linux's 3G/1G split), the stack's top and size, the mmap base, and the PIE base (`0x400000` on 386). Each `Mm` keeps its layout.

### Syscalls

`src/linux/nr.zig` adds the i386 table, generated from `asm/unistd_32.h`. The shared `Sys` enum keeps one name per call: where i386 reuses a name for an older form, the older one gets its own name (`old_select`, `old_mmap`, `old_getrlimit`, `oldstat32`, `statfs32`, the 16-bit id calls as `*16`), and the current form takes the generic name (`_newselect` is `select`, `ugetrlimit` is `getrlimit`, `getuid32` is `getuid`).

`sys.dispatch` reads the i386 registers, then gives the call to `ia32.serve`, which handles what's i386-only and rewrites the rest into the generic calls:

- The time64 calls become their generic names. Without them, the process's `time32` flag makes `timespec` reads and writes 32-bit.
- Split 64-bit arguments are joined. `mmap2` multiplies its offset by the page size. `old_mmap` and `old_select` read their arguments from memory.
- `stat64`, `fstat64`, `lstat64`, and `fstatat64` write the 96-byte `stat64`; the old stat calls the 64-byte `stat`, with its 32-bit fields truncated (Linux fails with `EOVERFLOW` instead; nothing seen uses these calls). `statfs64` and `fstatfs64` write 84 bytes.
- `fcntl64` is `fcntl`, whose record locks read the packed i386 `flock64` and the 32-bit `flock`.
- `socketcall` and `ipc` dispatch to the socket and SysV shared memory calls, with `shmctl` writing i386's `shmid64_ds`.
- `sigaction`, `sigaltstack`, `sysinfo`, and `getrlimit` write their i386 layouts.

The generic calls read and write `long`s and pointers at the process's word size: `iovec`, `msghdr` and its control messages, `timeval`, `itimerval`, `rusage`, `siginfo` in `waitid`, `robust_list`, `execve`'s string arrays, and `utimensat`'s `timespec`s.

### TLS

`set_thread_area` and `get_thread_area` are machine calls: entry -1 or 6 sets the base of the one TLS entry, which is written back as 6, and any other entry fails with `EINVAL`. The base is the vCPU's `X86Extra.tls`, so it's saved and restored with the thread like amd64's FS base, and `clone` with `CLONE_SETTLS` reads it from the `user_desc`. Each backend keeps a GDT with that entry:

- **Emulator.** Unicorn's 32-bit mode has no `GS_BASE` register, and its segment loads read the GDT through the MMU. Each 386 engine has a GDT page mapped read-only at `0xFFFFF000`, above any user mapping: flat ring-0 code and data that the engine runs with, and the TLS entry. Loading the flat descriptors at start also matters for 9front: any segment load makes QEMU recompute the 32-bit code and stack flags from the segment caches, which Unicorn's 32-bit mode leaves empty. `%gs` is loaded from the Ureg on each run when it changed: `0x33` or null.
- **v86.** The shim's GDT gets entry 6, a ring-3 data segment whose base the backend writes before each run when it differs from the vCPU's. The shim's restore path already reloads `%gs` from the Ureg. Vector `0x80` is a ring-3 gate, like 64, and an exit with trap `0x80` is a syscall.

A 9front 386 process that executes `int 0x80`, or a Linux one `INT $64`, gets a general protection fault, as it would on the real kernel.

### Signals

`signal.zig` builds and restores i386's `rt_sigframe` and `sigframe`, with the `sigcontext` in its 32-bit layout, the FXSAVE image in `fpstate` at offset 112, and the `retcode` trampolines for handlers without `SA_RESTORER`. `sigreturn` and `rt_sigreturn` restore the registers, keep `%gs` only if it's the TLS selector, and keep the flags outside 0xCD5 from the kernel's copy.

### Browser host

The browser host runs Linux programs from its root archive when the archive is a Linux tree (`etc/os-release`, or a `/lib/ld-*` loader): `--root /` now detects one under WASI, which has no realpath, as resolving a 9front root already did. The demo page's archive stays 9front's; a Linux one is built the same way with `tools/webroot.zig` and a list of paths from an Alpine x86 root.

Linux threads expose two scheduling gaps on the web host, where every vCPU is a coroutine on one thread. `sched_yield` returned at once, so a thread spinning on it while waiting for another never let that one start; it's now the kernel's `sleep(0)`, as 9front's is, which switches coroutines (and is the host's `sched_yield` natively). And a context that makes a syscall every few instructions (a reader looping around `sigsetjmp`, which calls `rt_sigprocmask`) halts before v86's slice ends, so it was never preempted; `run` now yields first once 2 ms have passed since its last yield. The browser's WASI shim also gains `fd_fdstat_set_flags`, which the web build imports and Chromium refused to link without.

## Rationale

**Run i386 on the emulator, not on KVM in compatibility mode.** An amd64 host's KVM could run 386 code in a 32-bit code segment under a 64-bit shim, faster than the emulator. It needs a compatibility-mode GDT and IDT in the KVM shim, an `int 0x80` gate, and 32-bit `iret` frames, none of which 9front's 386 binaries have needed either. It's left for a later proposal that would serve both: the goal here is the browser host, where v86 is the only option, and the emulator gives native hosts a way to test the same programs.

**The machine's architecture picks the ABI.** A machine runs one architecture, as it does for 9front, so `--arch 386` is needed for a Linux tree on a native host. Picking it from the program's ELF header would mean choosing the backend after resolving the program in the guest namespace.

**Rewrite into the generic calls.** Most i386 calls differ from the generic ones only in their argument registers or layouts. Rewriting the call and reading layouts at the process's word size keeps one implementation of each call; the i386-only calls (`socketcall`, `ipc`, the old stat and select forms) live in one namespace in `sys.zig`.

**A GDT entry, not a fake `%gs` base.** Unicorn and v86 both read segment bases from descriptors, and programs load `%gs` themselves, so the TLS entry must be in a GDT the CPU reads.

**No `AT_SYSINFO`.** A vDSO with `__kernel_vsyscall` would let programs use `sysenter`, which neither backend traps more cheaply than `int 0x80`.

## Compatibility

No CLI flags change: `--arch 386` already exists. Linux programs need a Linux root for 386, such as Alpine's x86 minirootfs, which `scripts/fetch.sh` now fetches to `.local/linux/alpine-386` beside the others. The 9front 386 personality is unchanged, except that a 9front process's `int 0x80` faults as it does on 9front. `X86Extra.tls` is now used on 386.

## Security

None new. i386 programs reach the same calls through the same policy; the multiplexers dispatch to the same implementations. The TLS descriptor is a ring-3 data segment whose base the guest picks and whose limit is 4 GiB, as on Linux; the user address space's page tables still bound what it reaches. The emulator's GDT page is read-only and outside the user address space.

## Done criteria

- [x] `h9 --arch 386 --backend emu --root .local/linux/alpine-386 /bin/busybox sh -c 'echo hello; ls /etc | wc -l'` runs on any host with the emulator.
- [x] `zig build integration -Darch=386 -Dpending` passes the Linux personality's cases ([linux-personality], [linux-threads], [linux-net]) on 386 with the 386 fixtures, including Go's `linux/386` programs.
- [x] In Chromium, the web host runs Alpine x86's dynamic busybox from a root archive made from `.local/linux/alpine-386`.
- [x] `test "an Alpine x86 shell runs on the emulator (demo) [linux-i386]"` passes.

## Implementation

1. ELF32 loading, the layout, and the i386 auxv.
2. The i386 syscall table and `ia32.serve`, and the generic calls at the process's word size.
3. Signal frames, and TLS on the emulator.
4. The 386 Linux fixtures (C and Go) and the Alpine x86 root.
5. v86: the TLS entry and the `int 0x80` gate, and Linux roots under WASI.

## Open issues

- KVM, HVF, and WHP: 32-bit compatibility mode on amd64 hosts, for 386 9front and Linux programs alike.
- A Linux archive for the demo page, and which programs it should carry: the page's size budget decides it.
- `vm86`, `modify_ldt`, and the LDT are not served; nothing seen so far uses them.
- On the web host, `getrusage` and `wait4` report no CPU time, so `files fsync_rusage` fails there (`cputime.thread` has no clock to read on WASI and gives zero; it's the web host, not the i386 ABI). A coroutine's time could be measured around its runs.

## Updates

- 2026-11-10: **Three TLS entries, and IRET.** 32-bit Wine takes a second TLS entry for `%fs`, which holds its TEB, beside libc's `%gs`, and returns from its syscalls with an IRET to ring 3. With one entry, its `set_thread_area` of entry -1 got 6 again and replaced libc's base, and the next `%gs` read faulted. So `set_thread_area` now serves Linux's three entries, 6 to 8: entry -1 gives the first one not yet given out, an empty descriptor frees one, and each has its own base (`X86Extra.tls` and `tls_more`, with `tls_used` for which are taken), saved with the thread. h86 and the Unicorn engine's GDT page hold all three, `%fs` is loaded from the Ureg as `%gs` is, and `sigreturn` keeps a TLS selector in either. h86 runs IRET and far RET when the popped CS is the running one, as same-privilege returns, and raises #GP otherwise. With these, Alpine x86's Wine 11 runs `cmd /c ver` and a 32-bit console program on h86. The case is `set_thread_area gives TLS entries 6 to 8, %fs keeps its own base, and IRET returns at ring 3`.
