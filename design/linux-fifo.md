---
slug: linux-fifo
title: Linux named pipes
status: draft
created: 2026-11-14
authors: [progrium]
depends: [linux-personality]
areas: [kern, linux]
branch: []
---

# Proposal: Linux named pipes

## Abstract

Serve Linux FIFOs. `mkfifo` and `mknod(S_IFIFO)` make a FIFO file that stays in the file system: an overlay node in overlays, and a real FIFO on host trees. `stat` shows it as `S_IFIFO`. An open of one by a Linux program is joined to a pipe kept for that file in a machine-wide table, so every process that opens it reads and writes the same pipe, with Linux's open, block, and EOF rules.

## Background

`mknodat` with `S_IFIFO` returns `ENOSYS` today, so `mkfifo` fails. In the Nix spike (Nov 13, 2026), that was the last thing to stop a nixpkgs source build. stdenv's fixupPhase makes FIFOs to feed its parallel `patchelf` and shebang workers, so every stdenv build fails there once everything else works. GNU make also tries a FIFO for its jobserver, then falls back to an anonymous pipe and prints a warning. Shell scripts use `mkfifo` for coprocess plumbing, as do `tee`-to-several-readers patterns, test suites (CPython's, coreutils', and gnulib's), and daemons that take commands on a FIFO.

Plan 9 has no FIFO file type. Its named pipe is a pipe posted in `/srv` (devsrv, srv(3)), which keeps a channel, not a path in a tree. A FIFO is an ordinary-looking name in a directory that any process can open by path. Every opener shares one pipe, which exists only while someone has it open.

The personality already does the same kind of mapping for symbolic links, which 9P doesn't have either. An overlay keeps them as its own node kind (`Nlink`), and a host tree keeps them as host links ([symlinks-in-root](symlinks-in-root.md)). File locks also have a machine-wide table keyed by a file's kernel identity (src/linux/locks.zig), so programs in different machines on one host file see each other's locks.

## Proposal

**Making one.** `mknodat(dirfd, path, S_IFIFO | mode, 0)` and `mkfifo` make a FIFO file at the path:

- In an overlay (the root's, and `/tmp`), it's a new node kind, `Nfifo`, which keeps the mode and times and has no data. `stat` gives size 0.
- On a host tree (`#U`), it's a host FIFO (`mkfifo(3)` on macOS and Linux). On Windows hosts, or a tree that refuses it, the call fails with `EPERM`, as `symlink` does there.
- On a 9P2000.L root ([dotl](dotl.md)), it's `Tmknod`. Plain 9P roots fail with `EPERM`.

The Linux personality tells a FIFO from a file the way it tells a link: by asking the device through a kernel call (`h9_fs_isfifo`, like `h9_fs_readlinkpath`), since a Plan 9 `Dir` has no type bits for it. `stat`, `lstat`, and `getdents` report `S_IFIFO` and `DT_FIFO`. `unlink` and `rename` work as on a file.

**Opening one.** An open of a FIFO file never opens the file itself. It joins the file's pipe in a table keyed by the file's identity (device, instance, and qid path, as locks.zig keys locks). The table is shared by every machine in the h9 process. A pipe is made at the first open and dropped when its last fd closes. It's a `#|` pipe with 64 KiB queues, so `read`, `write`, `poll`, `epoll`, and `fstat` are a pipe's.

- `O_RDONLY` waits until a writer has it open, and `O_WRONLY` waits for a reader. A signal interrupts the wait with `EINTR`.
- `O_RDONLY | O_NONBLOCK` returns at once. `O_WRONLY | O_NONBLOCK` with no reader fails with `ENXIO`.
- `O_RDWR` returns at once, holding both ends, as on Linux.
- Readers see EOF once every writer has closed, and writers get `EPIPE` and `SIGPIPE` once every reader has closed. A later open of the same file joins the same pipe if it's still held, or starts a new one.

**9front programs** see a FIFO as an empty file. `ls -l` shows it, `rm` removes it, and `cat` of it reads nothing. A 9front program that wants a named pipe uses `/srv`.

**Host programs** outside h9 opening a host-tree FIFO get the host's FIFO, not h9's pipe. They don't meet each other, as with file locks.

## Rationale

- **A pipe table, not the host FIFO.** Opening the host FIFO directly would block a kernel process in the host's `open`, out of reach of notes and `--timeout`. It would work only on host trees, not overlays or 9P roots, and it would make every byte a host round trip. The host FIFO is kept only so the name and type survive in the tree, which `--writable` users expect.
- **Keyed by identity, not path.** Two paths to the same file (a bind, a rename while open, a hard link on the host) must reach one pipe, and a new file at a removed FIFO's path must not. The qid is how locks.zig already identifies files.
- **Not through `/srv`.** devsrv's posted pipe is one pipe for its lifetime, and its readers and writers don't wait for each other. Building a FIFO on it would still need the table and the wait rules, plus a `/srv` entry per FIFO that a 9front program could see and remove.
- **In the personality, not a device.** The open rules (wait for the other side, `ENXIO`, `O_RDWR`) are Linux's, and only Linux programs make FIFOs. A kernel device for them would add a type to Plan 9's model that 9front programs don't use.

## Compatibility

There are no CLI or `Machine.Options` changes. Overlays gain a node kind, which lives only in memory and in exported overlays ([overlay-export](overlay-export.md) writes it as a FIFO). Host trees can now get FIFOs made in them, where a `--writable` path allows writes. Nothing in `third_party/` changes.

## Security

Making a FIFO is a create in a directory, so it's checked like any create: `--write` and `--writable` apply, and a read-only tree refuses it. Opening one reaches only the pipe in h9's table, never the host FIFO, so a FIFO on a host tree is no channel to host processes. The table's pipes are kernel memory, bounded by the fds the guest can open.

## Done criteria

Integration cases, tagged `[linux-fifo]`, with the Alpine root:

- [ ] `test "mkfifo makes a FIFO that stat reports [linux-fifo]"`, in `/tmp` and on a `--writable` host directory.
- [ ] `test "a writer and a reader meet through a FIFO [linux-fifo]"`: `mkfifo /tmp/f; echo hi > /tmp/f & cat /tmp/f` prints `hi`.
- [ ] `test "a nonblocking write open with no reader fails with ENXIO [linux-fifo]"`
- [ ] `test "O_RDWR opens a FIFO without waiting [linux-fifo]"`
- [ ] `test "a FIFO open is interrupted by a signal [linux-fifo]"`
- [ ] `test "two machines on one host FIFO share it [linux-fifo]"`
- [ ] Demo: `nix build --rebuild nixpkgs#hello` gets through fixupPhase, with the fixes from the Nix spike.

## Implementation

1. The overlay's `Nfifo` node, and `h9_fs_isfifo` for overlays, `#U`, and dotl.
2. `mknod` and `mknodat` with `S_IFIFO`, and `S_IFIFO` in `stat` and `getdents`.
3. The pipe table and the open rules in src/linux/sys.zig, with close accounting where `releaseLocks` already sees every close.
4. The cases, then the Nix demo.

## Open issues

- Whether `mknod` should also make character devices for the few that matter (`/dev/null` in a chroot that a test builds), or keep failing them with `EPERM`.
- Whether a FIFO's pipe should hold Linux's 64 KiB, or follow `F_SETPIPE_SZ`, which nothing in h9 serves yet.
