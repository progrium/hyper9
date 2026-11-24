---
slug: linux-chroot
title: chroot for Linux programs
status: implemented
created: 2026-11-24
authors: [progrium]
depends: [linux-symlinks]
areas: [kern, linux, sandbox]
branch: [main]
---

# Proposal: chroot for Linux programs

## Abstract

Let a Linux program's `chroot(2)` narrow its own view to a directory it can already reach, instead of failing with `EPERM`. The directory becomes the process's Linux root: absolute paths, absolute link targets, `..` at the top, and the programs it execs are found from there, and its children keep it. It can never widen a process's view past the Linux view, the machine's own root for Linux programs, which stays the sandbox's boundary. `mount`, `umount2`, `pivot_root`, `unshare`, and `setns` stay refused.

## Background

`chroot`, `mount`, `umount2`, `pivot_root`, `unshare`, and `setns` all return `EPERM` today (`src/linux/sys.zig`), as for an unprivileged process. Programs that build or install into a staging tree call `chroot` and stop there:

- **apk** runs each package's install scripts in a child that does `fchdir(root_fd); chroot(".")` before exec, even for `/`. Each script then fails, so packages with scripts (busybox's `post-install`, user creation, and `ca-certificates`'s trigger) half-install. h9x hits this.
- **`apk --root <dir>`**, **debootstrap**, and **build systems** that populate a tree and then run its own tools in it chroot into that tree.

Plan 9 has no `chroot`; a 9front program gets the same effect with `rfork n` and `bind`. For a Linux process, the kernel already resolves every path through its own namespace, from the process's root (`up->slash`), which the Linux personality sets to the Linux view (`#L`) at exec ([linux-symlinks](linux-symlinks.md) follows links from the same root). So a chroot is a choice of which directory that root is.

## Proposal

**Who.** `chroot(2)` is a Linux process's call; 9front programs keep `rfork n` and `bind`, and are unchanged. Any Linux process may call it: uid 0 in h9 grants nothing, and no uid is needed, since the call can only narrow what the process sees.

**The new root.** `chroot(path)` walks `path` as any Linux path is walked: relative to the working directory, following links, through the mounts and binds of the process's namespace, and checked by the sandbox's rules. It must be a directory: otherwise `ENOTDIR`, `ENOENT`, or the walk's own error. That directory becomes the process's Linux root:

- absolute paths start there,
- an absolute link target is followed from there, as [linux-symlinks](linux-symlinks.md) follows it from the process's root,
- `..` at the root stays at the root, as on Linux, whether it's written in a path, met in a link's target, or walked with `chdir`,
- exec finds the program, its `PT_INTERP`, and a `#!` interpreter from there.

**Only narrowing.** A process names only directories it can already reach, so its root can move down into its view or back up to the top of the Linux view, and never above it. `chroot` to the Linux view's own top (`chroot("/")`, or apk's `chroot(".")` with the working directory at `/`) is no chroot at all.

**The working directory** doesn't move, as on Linux. If it's under the new root, its name becomes its name from there, so `getcwd` and `/proc/self/cwd` give `/sub`, not `/r/sub`. If it's outside, it keeps working for relative paths, and `getcwd` gives its name from the old root, where Linux would give `(unreachable)/...`; a program that cares calls `chdir("/")` after `chroot`, as `chroot(1)` does.

**Open fds** don't change: reads, writes, and `fstat` work as before. A directory fd opened before the chroot also works as `openat`'s directory and with `fchdir`, even outside the new root, as on Linux; that's the classic way back out (`fchdir(old_root_fd); chroot(".")`), and it ends at the Linux view's top. `/proc/self/fd/N` names an fd by the path it was opened with.

**fork, clone, and exec.** A child keeps its parent's root, and exec keeps the caller's. A Linux thread has its own, set when it chroots, as each thread has its own working directory today (`CLONE_FS` isn't shared, spec/abi-linux.md). A 9front program that a chrooted process execs runs in the 9front view, which chroot doesn't touch, and a Linux program it runs in turn is back in the chroot.

**`/proc`, `/dev`, and the rest of the Linux view.** They're mounted on the Linux view's directories, not on the new root's, so a chroot has them only if its tree does, as on Linux, where a fresh chroot has no `/proc` until something mounts one. `/proc/self/exe`, `/proc/self/cwd`, and `/proc/self/fd/N` are the Linux layer's, not files, and keep answering in a chroot without `/proc`. Sockets are opened from the 9front view, and work in a chroot as outside one.

**Still refused.** `mount`, `umount2`, `pivot_root`, `unshare`, and `setns` stay `EPERM`. They change the namespace the machine's other processes share, not one process's view, and h9's binds already do what the guest is allowed to do there.

## Rationale

- **A per-process root, not a path prefix in the Linux layer.** Prepending the root's path to each path a program passes misses the walks the kernel makes on its own (absolute link targets, exec's interpreter, a `#!` line), and can't stop `..` at the root without resolving each path twice. The kernel's walk already starts at the process's root, so making the chroot's directory that root gets all of them right.
- **Not `bind newroot /`.** A bind changes the namespace (the `Pgrp`), which a Linux `fork` shares with its parent and siblings, so it would chroot them all. It also wouldn't keep `..` at the new top, and the Linux view's own mounts (`/proc`, `/tmp`) would keep showing through in places a chroot shouldn't have them.
- **Allowed for every uid.** Linux needs `CAP_SYS_CHROOT` because a chroot combined with a setuid program can trick it into reading the wrong `/etc`. h9 has no setuid programs and no privilege for them to gain, and the call reaches nothing the process couldn't reach already.
- **Escapes are allowed, and bounded.** Keeping a pre-chroot fd usable is what Linux does, and programs leave a chroot that way on purpose. The way out ends at the Linux view's top, the most the process could ever reach, so there's no reason to refuse it. A chroot is a compatibility feature, not a sandbox inside the guest: the machine is the sandbox.
- **`(unreachable)` not emulated.** It would make the working directory's name unusable as a path for the Linux layer's own walks from it (`openat` on an fd re-walks its directory's path), and programs that hit it treat it as an error anyway.
- **Keeping `mount` and `pivot_root` refused, and not faking them.** Succeeding without doing anything would silently break the programs that check afterwards. A `mount --bind` of `/proc` into a chroot is a real need for debootstrap-style tools, but it changes the shared namespace, and is left as an open issue.

## Compatibility

No CLI flags, exit codes, `Machine.Options`, or sandbox defaults change, and `--print` is unchanged.

- **Linux programs** that called `chroot` and got `EPERM` now succeed. One that treated `EPERM` as "not root, skip the chroot" now chroots; apk then runs its scripts as it would on Linux.
- **9front programs** see no change.
- **`third_party/`**: drawterm's `walkl` (chan.c) gains a check that keeps `..` at a chroot's root, beside its existing h9 changes for links.
- **The spec**: spec/abi-linux.md (Syscalls and The Linux view).

## Security

Nothing new is reachable. The new root is a directory the process walked to with the sandbox's checks, and every later walk from it is checked the same way. A process's root is never above the Linux view, and the ways out of a chroot (a pre-chroot fd, a working directory left outside it) lead only to what the process could already open before it. `..` is stopped at the root, which makes a chroot's view narrower than the same walks without it. The new root is held by the process's record (`Hproc.lroot`) and released at exit with the rest of its namespace.

## Done criteria

Integration cases, tagged `[linux-chroot]`, with the Alpine root and `tests/fixtures/linux/chroot.c`, each in the machine's `/tmp` and in the root's overlay:

- [x] `test "chroot narrows absolute paths to the new root [linux-chroot]"`
- [x] `test ".. at a chroot's root stays there [linux-chroot]"`
- [x] `test "an absolute link in a chroot resolves from its root [linux-chroot]"`
- [x] `test "the working directory keeps working across a chroot, named from the new root under it [linux-chroot]"`
- [x] `test "fork and exec keep the chroot [linux-chroot]"`
- [x] `test "an fd from before a chroot leads back out to the Linux view's top [linux-chroot]"`
- [x] `test "chroot to the Linux view's top changes nothing [linux-chroot]"`: `chroot("/")`, and apk's `chroot(".")` from `/`.
- [x] `test "chroot of a file or a missing path fails as on Linux [linux-chroot]"`
- [x] `test "mount, umount2, pivot_root, and unshare stay refused [linux-chroot]"`
- [x] `test "a socket leaves a chroot as it was [linux-chroot]"`
- [x] `test "busybox chroot runs a dynamic program in a staging tree [linux-chroot]"`: `chroot r /bin/sh -c ...` with busybox and `ld-musl` copied into a host directory, so exec finds the interpreter in the chroot.

## Implementation

1. `src/kern/linux.c`: `h9_linux_chroot`, which walks the path, keeps the directory as the process's Linux root (`Hproc.lroot`, marked so `h9_linux_inview` still knows the process is in the Linux view), renames the working directory, and makes it `up->slash`. `h9_linux_setslash` goes back to that root rather than `#L` after a stay in the 9front view (exec, sockets), and `h9_linux_dotfd` walks a pre-chroot fd's path from the view's top when the chroot's doesn't reach it.
2. `src/kern/proc.c`: forks inherit the root, and `h9_kern_release` lets it go.
3. chan.c's `walkl`: `..` at the root stays there (`h9_fs_atroot`).
4. `src/linux/sys.zig`: `chroot` calls it; the rest stay `EPERM`.
5. The cases, the fixture, the manual, and the spec.

## Open issues

- **Mounts into a chroot.** debootstrap and similar tools `mount --bind /proc` (and `/dev`, `/sys`) into the tree before chrooting. Allowing a bind mount of a directory the process can already reach onto one under its chroot, for that process and its children only, would cover them, but needs a per-process namespace that a Linux `fork` doesn't share today.
- **`(unreachable)`** for a working directory left outside the root, if a program turns out to depend on it.

## Updates

- 2026-11-24: Built with the proposal on `claude/project-thread-mljsxy`, with the cases above passing on the native backend.
