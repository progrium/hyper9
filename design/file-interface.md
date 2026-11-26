---
slug: file-interface
title: A wider file interface inside the kernel, with 9P2000 as a view
status: draft
created: 2026-11-21
authors: [progrium]
depends: [kernel-port]
areas: [kern, linux, ninep, tests]
branch: [dev, file-interface]
---

# Proposal: A wider file interface inside the kernel, with 9P2000 as a view

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

The kernel's device interface is 9P2000's operations: attach, walk, stat, open, create, read, write, remove, and wstat. Linux programs need more from a file than those say: whether a read would block, symbolic links, owners and modes and times as Linux has them, atomic rename, hard links, locks, and fsync. Today each is worked around at an edge. This proposal adds them to the device interface as optional operations, each with a default that's today's behaviour, so a device implements only what it has. The Linux ABI calls them directly. 9front processes and 9P2000 clients see the same nine operations as before, and a 9P2000.L server or client maps to the wide form without going through the narrow one. It's delivered in three parts, each of which removes a workaround.

## Background

The kernel speaks 9P2000 inside and translates at its edges, so a Linux process on a 9P2000.L root goes from Linux to 9P2000 to .L, and loses detail twice. The workarounds are the evidence.

- **Readiness.** devmnt can't say whether a read would block, so `poll` and `epoll` on a mounted `/net` conversation are served by `src/kern/linuxnet.c`: 1,300 lines, a hook in `qio.c`, and a read-ahead kernel process per conversation.
- **Symbolic links.** They're in-memory nodes in `#O`, or special files in a 9P2000.L root that [dotl](epoch-0/dotl.md) resolves, and a device in between can't carry one.
- **Hard links and rename.** `link` copies the file. `rename` across directories is a copy and a remove where the server has no better wstat.
- **fsync** is a null wstat, which a server may or may not honour.
- **Locks.** `fcntl` and `flock` locks poll every 2 ms, and `#λ` needs an exemption in the vendored `chan.c`.
- **Attributes.** Numeric ids, `nlink`, device numbers, and nanosecond times are synthesized from a `Dir`, or carried beside it for a .L root.

This gives up the kernel being a Plan 9 kernel exactly, inside. Jeff agreed to that on Nov 21, 2026, when the redesign was discussed. The condition this proposal sets itself is that 9front programs and 9P2000 clients can't tell.

[kernel-port](kernel-port.md) comes first for two reasons. The device table has to be h9's own to grow, and the port has to be a faithful translation, checked against 9front, before anything widens. That proposal shapes the table so operations can be added with defaults.

## Proposal

### The rule

A device is a table of the nine operations, which every device has, plus optional ones. An optional operation a device lacks falls back to a default built from the nine, which is what h9 does today. Nothing that's visible through 9P2000 changes: a `Dir` is still a `Dir`, a symbolic link is still whatever it looked like to a 9front `ls`, and error strings are the same.

### Part 1: readiness

- `ready(chan, events) -> events`, and `watch(chan, events, waker)`: whether a read or a write would block now, and a callback when that changes.
- Implemented by pipes, queues, the console, devip conversations, `#λ`'s sockets and eventfds, and devmnt for servers that say they support it. The default is "always ready", which is right for files.
- `poll`, `select`, and `epoll` in the Linux ABI use it directly. `linuxnet.c`'s read-ahead processes and the `qio.c` hook go.

### Part 2: links and attributes

- `readlink`, `symlink`, and `link`, and a `nofollow` flag through `walk` for the Linux ABI's path resolution.
- `getattr(chan, mask) -> Attr` and `setattr(chan, mask, Attr)`, with numeric ids, mode, `nlink`, rdev, sizes, and nanosecond times. The default builds an `Attr` from `stat`.
- `rename(chan, newdir, name)`, atomic where the device can do it. The default is today's wstat, or copy and remove.
- Implemented by the overlay, the host tree device, devdotl (which maps each to its 9P2000.L message), and tmpfs-like devices.

### Part 3: locks and fsync

- `lock(chan, range, kind, wait)` and `unlock`, with blocking through Part 1's wakers instead of polling.
- `fsync(chan, data_only)`. The default is the null wstat.
- Implemented by the host tree device and devdotl. In-memory devices keep lock tables in the kernel.

### Views

- **9front processes** call the nine operations. A symbolic link reads as it does today.
- **A 9P2000 server** ([kernel-serve](epoch-0/kernel-serve.md)) serves the nine. A 9P2000.L server, where one is added, serves the wide form.
- **devmnt** uses the nine against a 9P2000 server, and devdotl uses the wide form against a 9P2000.L one, so a Linux process on a .L root translates once.

## Rationale

**Why inside the kernel and not at the edges.** The edges are where it is now, and each workaround is a place where two layers each know half of something. Readiness can't be added at an edge at all: only the device knows.

**Why optional operations with defaults.** Most devices are small and Plan 9-shaped, and should stay that way. A device author adds an operation when the default isn't good enough.

**Why not adopt 9P2000.L as the internal interface.** It would make the Plan 9 side the translated one, and it has no readiness either. The wide form is the nine operations plus what's missing, so the Plan 9 view is a subset and not a translation.

**Why three parts.** Each stands alone, removes a named workaround, and can be judged by whether that workaround is gone. Readiness is first because it deletes the most code and fixes the most visible cost.

**What's given up.** The kernel's device interface no longer matches 9front's, so a 9front device driver doesn't drop in unchanged. h9 has ported none that way.

## Compatibility

- **9front programs and 9P2000 clients.** No change. The conformance suite from [kernel-port](kernel-port.md) is the check.
- **Linux programs.** Locks block instead of polling, `poll` on a mounted connection no longer reads ahead, `link` makes a link where the device can, and `fsync` reaches the server that can honour it.
- **CLI, `Machine.Options`, exit codes, and sandbox defaults.** Unchanged.
- **`third_party/`.** The `chan.c` and `qio.c` patches are already gone with the port.

## Security

Policy checks move with the operations: each new operation is checked where `open` and `wstat` are checked now, with the same read and write rules. `symlink` and `link` are the ones to watch, since a link is a way to name a file from somewhere else. A link is made only within one device instance, and resolution through a symbolic link is checked at the target as a fresh walk, so a link can't reach what a path couldn't ([symlinks-in-root](epoch-0/symlinks-in-root.md) has the rules for host trees).

## Done criteria

Part 1:

- [x] `test "epoll on a mounted /net conversation without read-ahead [file-interface]"` passes, and `src/kern/linuxnet.c`'s read-ahead processes are deleted.
- [x] `test "poll on a pipe, a pty, and an eventfd through ready [file-interface]"` passes.

Part 2:

- [x] `test "symlink through a bind, an overlay, and a .L mount [file-interface]"` passes.
- [x] `test "link makes a second name, not a copy [file-interface]"` passes on the host tree device and devdotl.
- [x] `test "rename across directories is atomic [file-interface]"` passes on the host tree device and devdotl.
- [x] `test "a 9front ls sees the same Dir as before [file-interface]"` passes.

Part 3:

- [x] `test "a blocked fcntl lock wakes without polling [file-interface]"` passes, and the 2 ms poll is deleted.
- [x] `test "fsync reaches a .L server as Tfsync [file-interface]"` passes.

All parts:

- [ ] The Linux cases, PostgreSQL's included, pass on every engine with none newly skipped.
- [ ] [kernel-port](kernel-port.md)'s conformance transcripts are unchanged.
- [ ] [spec/kernel.md](../spec/kernel.md), [spec/abi-linux.md](../spec/abi-linux.md), and [spec/ninep.md](../spec/ninep.md) describe the interface and its views.

## Implementation

1. Part 1: `ready` and `watch` on queues and pipes, then devip, then `#λ`, then devmnt. Move `poll` and `epoll` over, and delete the read-ahead.
2. Part 2: `getattr` and `setattr`, then `readlink` and `symlink`, then `link` and `rename`, a device at a time, starting with the overlay.
3. Part 3: locks on Part 1's wakers, then `fsync`.
4. devdotl on the wide form, so a Linux process on a .L root translates once.
5. The spec.

## Open issues

- Whether this should be three proposals. As written it's one, with Done criteria grouped by part, and it can be split if the parts finish far apart, as the process asks.
- Whether a 9P2000 server can advertise readiness to devmnt, or whether Part 1 over 9P2000 is always "ready" with a blocking read. As written, only servers that say so support it, and how they say so isn't designed.
- Whether extended attributes belong in Part 2.

## Updates

**2026-11-26, Part 2 on the file-interface branch.** The six operations are built, as [spec/kernel.md](../spec/kernel.md) describes: optional fields of a Zig device's `dev.Ops`, and a `Devx` table of C function pointers (`src/kern/devx.h`) for a C device, with the defaults in `dev.zig` and the calls on paths in `src/kern/syswide.zig`. Some things it found:

- **devdotl's side is devmnt's.** The 9P2000.L server is behind a `#ℓ` conversation that devmnt mounts, so the operations are devmnt's, which sends `Tsymlink`, `Treadlink`, `Tlink`, `Trename`, `Tgetattr`, and `Tsetattr` with its own fids to a mount whose `#ℓ` translates to .L, and the translator maps them. Every other mount gets the defaults, so 9P2000 servers see only 9P2000. The `#ι` index passes them on, making the fids real. This also replaces the translator's `DMSYMLINK` create and its link-reads-as-target open, which were h9's own 9P2000 extensions, not anything a 9front program used.
- **Deleted workarounds:** `fscheck.c`'s `h9_fs_readlinkpath`, `h9_fs_chanreadlink`, `mntreadlink`, `h9_fs_symlinkpath`, `h9_fs_mntsymlink`, and `h9_fs_renamepath`; `src/kern.zig`'s `renameAcross`; and the overlay's own symlink and rename calls into devfs. The per-process `h9_fs_nofollow` flag remains only for `O_NOFOLLOW` on open; `namecx`'s `nofollow` replaces it elsewhere.
- **The overlay has no `link`**, so a hard link in an overlay, the root's `/tmp` and `/usr` included, is still the default copy, and so is one on Windows hosts, whose `#U` has none. A link count in the overlay is the lower tree's.
- **The default rename across directories is still `EXDEV`**, not a copy and remove, since that's what dev did and `mv` copies on `EXDEV` anyway.
- **`setattr` has no device of its own yet** but devmnt's `Tsetattr`: the host tree and the overlay take the default `wstat`. The Linux ABI doesn't call it yet; `chmod`, `truncate`, and `utimensat` still `wstat`.
- **stat's owner is unchanged**: the Linux ABI takes the link count, ctime, and nanoseconds from `getattr`, and still reports the caller as every file's owner.
- The new cases are tagged `[file-interface]`, and pending until the proposal is accepted; with `H9_TEST_PENDING=1` they pass on sud and hcpu. The "9front ls" case's expected output is what dev's h9 printed.

**2026-11-26, Part 1 on the file-interface-2 branch.** `ready` and `watch` are built (`src/kern/ready.zig`), as [spec/kernel.md](../spec/kernel.md) describes, on pipes, ptys, the console, `#ε`, devip, and devmnt, and `poll`, `select`, and `epoll` use them; the read-ahead (`src/kern/rconv.zig`) and qio's `h9_qwake` hook are deleted. Some things it found:

- **How a server says so** (the second open issue): by version negotiation, which version(5) allows. devmnt offers `9P2000.ready` in a mount's own `Tversion`, and kserve answers it; a server that answers `9P2000` gets no `Tready`. `Tready` (type 160) is `tag[2] fid[4] events[4]`, with bit `0x40000000` asking for an answer at once, and `Rready` (161) is `tag[2] events[4]`, as [spec/ninep.md](../spec/ninep.md) gives. A waiting `Tready` is an asynchronous devmnt request, whose reply a reader kproc per mount reads when no process is waiting for one.
- **A 9front server's `/net` is always ready**, so a non-blocking read of a conversation mounted from one blocks, where the read-ahead answered `EAGAIN`. So does one mounted through a `#ℓ` conversation, which answers devmnt `9P2000` itself.
- **A remote `SO_ERROR` is a guess**: `ECONNREFUSED` when the server says `Err`, since the conversation's error isn't carried.
- `MSG_PEEK` and `FIONREAD` on a remote conversation read into a buffer per conversation that later reads take first, the one place something is still read ahead.

**2026-11-26, Part 3 on the file-interface-2 branch.** `fsync(chan, datasync)` is built, with the null wstat as its default, and devmnt sends `Tfsync`, with `datasync`, to a .L mount; the Linux ABI's `fsync` and `fdatasync` call it. A blocked `F_SETLKW` or `flock` waits on Part 1's wakers, which each change to the lock table fires, and the 2 ms poll is deleted. Some things it found:

- **`lock` and `unlock` aren't device operations yet.** The Linux ABI's one table (`src/abi/linux/locks.zig`) still serves every device, so a lock is seen by the programs of every machine in the h9 process and by none outside it, as before; a host tree's `fcntl` locks and a .L server's `Tlock` would be the devices' own, and a lock wait would hang on the device's waker rather than the table's.
- The lock case compares a lock's wake with a pipe reader's in the same run, since a loaded host slows both: a 2 ms poll added most of a millisecond or more to the median.
