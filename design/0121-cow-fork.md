---
id: 121
slug: cow-fork
title: Copy-on-write fork and demand-loaded file pages for Linux processes
status: draft
created: 2026-11-08
authors: [progrium]
depends: [18, 49]
areas: [linux, kern, vmm]
---

# Proposal: Copy-on-write fork and demand-loaded file pages for Linux processes

## Abstract

A Linux process's `fork` copies every allocated page of its parent today, and `exec` and private file mappings copy the whole file into fresh pages up front. Both count against `--memory`, so a toolchain that forks a large process and execs another large one runs out of guest memory long before it uses that much. This proposal makes `fork` share the parent's private chunks read-only and copy a chunk only when either side writes it, and fills private file pages (an executable's segments included) from the file the first time they're touched.

## Background

[linux-personality](0018-linux-personality.md) left both as later work: "`fork` copies the VMAs eagerly, as `rfork` copies segments. Copy-on-write is later performance work." Its Memory section planned private file mappings filled "eagerly for small files, or chunk by chunk on fault", and only the eager half was built.

What's there now (`src/linux/mm.zig`):

- An `Mm` is a sorted list of VMAs over the vmm's address space, with pages allocated on first touch in 1 MiB chunks. A chunk's memory is a `Pages`, which is reference counted already, because `MAP_SHARED` chunks are shared by the Mms of a fork and by processes mapping one file (`shmfile.zig`).
- `Mm.fork` creates a new Mm with the same VMAs, shares `MAP_SHARED` chunks, and copies each private chunk into new pages (`copySparse`, which skips zero pages).
- `mmap` of a private file reads the whole range into the mapping's pages at the call (`hostEach` and `pread`). `exec` reads the whole executable into host memory and writes each `PT_LOAD` segment into guest pages (`elf.load` and `hostWrite`).
- Pages come from the backend's guest-physical allocator, so all of them count against `--memory` (default 1 GB).

Zig 0.16 shows the cost (see 0018's Updates, 2026-11-08). `zig` is a 170 MB static executable. `zig cc` and `zig build` fork `zig` and exec `zig` again for clang, and then LLD, while the parent keeps its own heap. Each child copies the parent's touched memory at `fork`, then loads all 170 MB again at `exec`, though it runs a small part of it. With the default 1 GB, a cold `zig cc` and `zig build -Doptimize=ReleaseFast` fail with "SystemResources" when the spawn fails, and on HVF a cold `zig build` with LLD needed more than 3 GB.

The same pattern is common: shells, `make`, `git`, and Python's `subprocess` fork a process that's often large and exec right away. (Go's `os/exec` uses a `vfork`-like `clone` on Linux, which shares the Mm and doesn't pay.) Servers that fork workers (PostgreSQL) keep most of the parent's pages unchanged for the child's life.

## Proposal

### Copy-on-write fork

- **Sharing at fork.** `Mm.fork` gives the child the parent's `Pages` for every private chunk, as it does for shared ones, and takes a reference on them. A private chunk whose `Pages` has more than one reference is copy-on-write in every Mm that holds it.
- **Mapped without write.** `remap` and `remapShared` map a copy-on-write chunk's runs without write permission, whatever the VMA allows. Reads and execution of the shared pages go on at full speed in both processes.
- **Before fork returns,** the parent's runs are remapped without write and shot down on the vCPUs of its other threads ([linux-threads](0049-linux-threads.md)'s `settle`), so no write made after `fork` returns in the parent can reach the child. Writes other threads make during the `fork` call land before or after the snapshot, as on Linux.
- **The first write** to a copy-on-write chunk faults. `Mm.fault` sees a write the VMA allows on a chunk whose `Pages` is shared and private: it allocates new pages, copies the old ones (`copySparse`), drops its reference on the old ones, and remaps the chunk writable. If its reference is the only one left (the other side wrote first, or exited), it remaps without copying.
- **Writes by the host** on the guest's behalf (`touch` with `write`, `copy` to the guest, `hostSlice` with `write`, `hostWrite`) break the copy-on-write of the chunks they cover first, in the same way, so `read` into a buffer after `fork` doesn't write into the other process's pages.
- **Running out.** A copy that finds no memory is what a first touch past `--memory` is today: a guest write gets `SIGSEGV`, with "virtual memory allocation failed" under `--debug`, and a syscall's buffer gets `EFAULT`. Linux's OOM killer would end some process in the same spot; `fork` itself no longer fails for want of memory.
- **Unchanged:** `MAP_SHARED` chunks and System V segments are shared as they are now. `vfork` children and threads share the Mm itself, not its chunks. `MADV_DONTNEED` on a copy-on-write chunk drops this Mm's reference and leaves the range unallocated (zero), rather than zeroing pages the other process still reads.
- **Accounting.** `/proc/n/status`'s `VmRSS` counts a shared chunk in each process that maps it, as Linux counts shared pages. `--memory` counts the pages once, as allocated.

### Demand-loaded private file pages

- **Private file mappings** keep a reference to the open file (its Chan) and its offset in the VMA, and get their pages chunk by chunk on first touch: a fault or a host access allocates the chunk, reads the file's bytes for the parts of the chunk the VMA covers, and zeroes the rest, as `mmap` does for the whole range today. The VMA's reference is dropped when the last of its pages is unmapped.
- **`exec`** reads the ELF headers and the interpreter path, and maps each `PT_LOAD` segment as a private file mapping of the executable, so its pages load as they're touched. The bss and a segment's tail past `p_filesz` stay zero-filled as now. A segment's pages that share a page with its neighbour (two segments in one page) are read eagerly, as there's no single file range for them.
- **Fork** of a chunk that hasn't been loaded yet copies nothing: the child's VMA takes its own reference on the file and loads the chunk itself when it touches it.
- **A file that changes** after it's mapped shows the change in chunks not yet loaded, as Linux shows it in pages not yet faulted. Linux refuses writes to a running executable (`ETXTBSY`); h9 doesn't, so a rebuilt executable written in place while it runs can give its old process a mix. Compilers and package managers write a new file and rename it over the old one, which keeps the old file's Chan, and so its contents, for the running process on every file server h9 serves roots from today.

## Rationale

**Chunks, not pages.** Copy-on-write by 1 MiB chunk keeps the Mm's structure as it is: a chunk is one `Pages`, mapped as a few runs, and the region count the backends see doesn't grow. A first write after `fork` copies up to a megabyte, but `copySparse` skips zero pages, and a fork-then-exec child writes only a few chunks (its stack, a little heap, and libc's data) before `exec` drops them all. Page granularity would need a `Pages` per page, or per-page reference counts and runs split at every copied page, and would multiply regions in the HVF backend, whose region lookup is still a scan. If measurements show the chunk copies matter for long-lived forked workers, per-page copying can come later inside `Mm`, as 0018's vmm changes (range `unmap` and `protect`) land.

**Raising the default `--memory`.** It hides the problem for Zig but not for larger trees, still costs host memory on HVF and KVM when pages are touched, and doesn't make `fork` faster: each spawn still copies the parent's touched memory and the whole executable.

**Making programs use `vfork` or `posix_spawn`.** h9 already serves `vfork` by sharing the Mm, and programs that use it don't pay. But h9 runs unmodified binaries, and Zig, glibc's `system`, and many runtimes call `fork`.

**A shared page cache for executables.** Mapping one read-only copy of `zig`'s text into every process running it would save more than loading on demand: every child would share the parent's pages. But a file chunk can be shared only where the file offset and the address agree modulo the chunk size, as `MAP_SHARED` file mappings require today, and ELF segments are aligned to pages, not to 1 MiB. Copy-on-write fork gets most of the same sharing for the fork-and-exec-the-same-binary case already, since the child's text pages are its parent's until `exec`; a cache can come later with page-granular mappings.

**Kernel same-page merging** (deduplicating identical pages after the fact) saves memory without changing `fork`, but costs CPU scanning and doesn't help a `fork` that fails before there's anything to merge.

## Compatibility

No CLI flags, exit codes, or `Machine.Options` change. A program that ran before still runs, with less memory. Two behaviours move: `fork` no longer fails with `ENOMEM` when the parent is large, and running out shows up later, as `SIGSEGV` at the write that needed a copy, as a first touch past `--memory` does already. A private file mapping or an executable whose file changes while it's mapped can see the new bytes in pages it hadn't touched, where it saw a snapshot before. 9front processes are unchanged.

## Security

Pages are newly shared read-only between a parent and child that were identical at `fork`, so neither can read anything it couldn't before. The guarantee needed is that neither can write the other's: guest writes go through write-protected mappings (shot down before `fork` returns), and every host write on the guest's behalf breaks the sharing first, so there's no path to a shared private chunk that skips the check. The design keeps those writes behind `Mm`'s existing entry points, and the integration cases test them. A VMA's reference to a file is the same access the process had through its fd when it mapped it, so demand loading reaches nothing new; a file whose permissions change later can still be read through an existing mapping, as on Linux.

## Done when

Demos:

- `zig cc -o hello hello.c` and `zig build -Doptimize=ReleaseFast` from a cold cache under the default `--memory`, on HVF and on the emulator.
- `zig build test` from a cold cache under the default `--memory` on HVF.

Integration cases:

- `test "a fork of a process with 600 MB of written heap runs under --memory 1g, and parent and child see their own writes [cow-fork]"`
- `test "after fork, a read() into a buffer, a write from another thread, and a futex word change stay in the process that made them [cow-fork]"`
- `test "a write after fork that finds no memory gets SIGSEGV, and the machine and the other process go on [cow-fork]"`
- `test "MADV_DONTNEED after fork zeroes the range in one process only [cow-fork]"`
- `test "a private mapping of a 200 MB file costs only the chunks touched, as VmRSS shows [cow-fork]"`
- `test "an executable's untouched segments aren't loaded: a 170 MB static binary runs in 64 MB [cow-fork]"`
- The existing `MAP_SHARED`, System V, `vfork`, and thread cases in [18] and [49] pass unchanged.

## Implementation

1. Copy-on-write in `Mm`: shared private chunks in `fork`, write-less runs in `remap` and `remapShared`, the copy (or reuse) in `fault` and in the host write paths, `MADV_DONTNEED`, and the shootdown before `fork` returns. Cases 1 to 4.
2. Demand-loaded private file mappings: a Chan reference and offset in the VMA, filling chunks on populate, and fork's handling of unloaded chunks. Case 5.
3. `exec` through file mappings in `elf.load`, reading headers only up front. Case 6, and the Zig demos.
4. SPEC.md's memory section, and an Updates note on [18].

## Open issues

- 9front `rfork` copies segments eagerly too, and [go-compat](0007-go-compat.md)'s `os/exec` case needs `--memory 4G` for it. Copy-on-write segments would follow the same plan in `src/segment.zig`, but semaphores key waiters on host addresses ([semaphores](0003-semaphores.md)), so moving a page under a waiter needs care. A separate proposal, or this one's scope?
- Per-page copy-on-write, if chunk copies show up in long-lived forked servers.
- Whether `exec` should still read the whole file for small executables, where one read is cheaper than many faults.
