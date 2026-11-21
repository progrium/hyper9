---
slug: linux-symlinks
title: Linux symlinks resolved in the guest's namespace
status: draft
created: 2026-11-21
authors: [progrium]
depends: [symlinks-in-root]
areas: [kern, linux, sandbox]
branch: []
---

# Proposal: Linux symlinks resolved in the guest's namespace

## Abstract

For Linux programs, follow symbolic links in the kernel's walk, from the process's own root, as Linux does, instead of in the device that holds them. An absolute target starts at the Linux view's `/`, whatever tree the link is in, and a relative one from the link's directory as the program walked to it. Devices stop at a link and hand back its target rather than following it, and a directory listing shows a link as a link, with or without a target. 9front programs keep today's behaviour.

## Background

Today a link is followed by the device that holds it, never by the namespace:

- **An uncontained host tree** (the cwd, `--writable` paths, and binds of them) follows links with the host's `stat`, so an absolute target is a host path: `/mise/installs/python/3.11/bin/python3` means the host's `/mise`.
- **A contained tree** ([symlinks-in-root](epoch-0/symlinks-in-root.md); every `--dir` on `#L`) resolves links inside itself, so an absolute target starts at that tree's top.
- **An overlay** resolves its in-memory links (`Nlink`) from the overlay's own top, and a **9P2000.L mount** from its attach root ([spec/ninep.md](../spec/ninep.md)).
- **A listing** shows a link with its target's `Dir`, and leaves it out when the target is missing or loops (spec/sandbox.md, Contained trees). An uncontained tree does the same, since `stat` fails. `lstat`, `readlink`, and `unlink` of such a link work.

None of these is the process's root, which is what Linux resolves an absolute target from. So a link whose target is in another tree, a layer, or a bind doesn't resolve:

- **A Python venv** made in a bound `/app` has `bin/python -> /mise/installs/python/X/bin/python3`, a runtime from another tree. Under an uncontained bind, that's the host's `/mise`; uv can't start the interpreter, and `uv sync` fails ("Failed to query Python interpreter ... Exec format error").
- **Layers.** Stacking a runtime, a deps, and an app layer on `#L` as separate `--dir` members (as an image's layers would be) puts the venv in the deps layer and its target in the runtime layer. Each member is contained, so the link resolves inside the deps layer and finds nothing.
- **mise** lists an aqua tool's binaries in `.mise-bins` as absolute links (`uv -> /mise/installs/uv/0.13.7/uv-.../uv`), and its shims are links to the mise binary's path in the guest.
- **Nix** profiles and `/run/current-system`, and Debian's `/etc/alternatives`, are trees of absolute links into other trees (`/nix/store`).
- **Dangling links don't list.** npm and mise delete a directory by listing it and removing what they find, then `rmdir`; a link whose target is gone (a package already removed, a path only the guest has) isn't listed, isn't removed, and the `rmdir` fails with `ENOTEMPTY`.

These came up building apps for h9 from Railpack plans with mise runtimes (`h9build`, in progrium/scratch): Node and Go apps build and run, and Python with uv can't, for the first reason; the second and third forced workarounds.

## Proposal

**Who.** The rules below apply to walks a Linux process makes: its path syscalls, exec, and the interpreter lookup. A 9front process's walks are unchanged, and devices follow links for it as they do today.

**Devices stop at links.** In a Linux process's walk, devfs (contained or not), the overlay, and a 9P2000.L mount don't follow a link they meet. The walk ends at the link, which `stat`s with `DMSYMLINK` (9P2000.u's bit, `0x02000000`, as [linux-fifo](linux-fifo.md) uses `DMNAMEDPIPE`) and its own size and times, and its target is read as today (`h9_fs_readlink`, `Treadlink`).

**The kernel follows them.** When a walk ends at a link with names left to walk, or at the last name of a lookup that follows links, the walk starts again:

- an absolute target from the process's root (the Linux view, `#L` with everything mounted and bound on it),
- a relative target from the directory the link is in, as the walk reached it, with the rest of the path appended,
- and more than 40 links in one lookup is `ELOOP`.

So a link is resolved by the same walk, through the same mounts, binds, and stacks, as the path the program would get by writing its target out.

**The last name.** A lookup follows a link in its last name unless the call says not to, as Linux's do: `lstat`, `readlink`, `unlink`, `rename`, `symlink`'s new name, `O_NOFOLLOW` (with `O_PATH`, an fd for the link itself), and `AT_SYMLINK_NOFOLLOW` act on the link.

**Listings.** For a Linux process, a directory read shows a link as a link (`DMSYMLINK`, so `getdents` gives `DT_LNK`), whether its target exists or not.

**Contained trees** stay contained for 9front programs. For a Linux program the boundary is the process's root instead of the tree's top: the guest namespace is the boundary.

## Rationale

- **In the kernel's walk, not the Linux layer.** The Linux layer could resolve paths itself, a name at a time with `readlink`, before every call. That's a host round trip per name of every path, races the walk the call then makes, and misses the walks the kernel makes on its own (exec's interpreter, a `#!` line).
- **From the process's root, not the tree's or the host's.** The tree's top is right only when one tree is the whole root, as a single image directory was when contained trees were added. The host's `/` is never the guest's. The process's root is what the program, and whoever made the link, meant.
- **Not a retry under `/mnt/term`.** An absolute link in a host tree that names a host path (`~/.config -> /Users/me/dotfiles/config`) would resolve if a failed lookup were retried at `/mnt/term/<target>`, where allowed host paths appear. That's not Linux's rule, would make a lookup's meaning depend on what's missing, and would hide the missing target. It's left as an open issue.
- **A mode bit, not a kernel call per entry.** As with FIFOs, `stat` and `getdents` see `DMSYMLINK` in the `Dir`, so a listing needs no extra call per name.
- **Linux only.** 9front programs don't make or expect links, and a listing full of `DMSYMLINK` entries would be new to them.

## Compatibility

No CLI flags, exit codes, or `Machine.Options` change. `--print` is unchanged.

- **Linux programs** see Linux's semantics: links into other mounts and layers resolve, and dangling links list. A link in an uncontained host tree whose absolute target is a host path that the guest doesn't see at that path no longer resolves.
- **9front programs** see no change.
- **`third_party/`**: the vendored `chan.c` gains a hook in `namec`'s walk where it already calls `h9_fs_anchor`, and devfs-posix's walk and directory read take a mode that doesn't follow links. Both are h9 changes the vendored tree already carries in the same places.
- **The spec**: spec/sandbox.md (Path resolution, Contained trees), spec/ninep.md (9P2000.L links), and spec/abi-linux.md.

## Security

A Linux program's links now reach only names in its own namespace, each walked and checked by the access rules like a path the program wrote out. That's narrower than today for uncontained host trees, whose links can lead to any host path the rules allow, and no wider for contained trees: an absolute link there can now reach other mounts in the guest's namespace, which the program could open by name anyway. The 40-link limit bounds the work a lookup can make. A host process following a link the guest wrote under a `--writable` path is unchanged, and still a caveat `--print` lists.

## Done criteria

Integration cases, tagged `[linux-symlinks]`, with the Alpine root:

- [ ] `test "an absolute link in a bound host tree resolves from the Linux root [linux-symlinks]"`: a link `/app/x -> /opt/y` in a `--bind` of a cwd directory at `#L/app` opens `/opt/y` from another `--dir`.
- [ ] `test "an absolute link in one #L layer resolves into another [linux-symlinks]"`
- [ ] `test "a relative link resolves from its own directory across a bind [linux-symlinks]"`
- [ ] `test "a dangling link lists and removes [linux-symlinks]"`: `ls` shows it, and `rm -r` of its directory succeeds, in a host tree and an overlay.
- [ ] `test "lstat, readlink, and O_NOFOLLOW act on the link [linux-symlinks]"`
- [ ] `test "a loop of links is ELOOP [linux-symlinks]"`
- [ ] `test "a 9front program's walk through a contained tree is unchanged [linux-symlinks]"`
- [ ] Demo: h9build's `python-uv` example builds, and its app runs from separate runtime, deps, and app layers.

## Implementation

1. The walk mode: a Linux process's walks ask devices not to follow links. devfs (both modes), the overlay's `Nlink`, and the 9P2000.L translator stop at a link, mark it `DMSYMLINK`, and list links, including dangling ones.
2. The kernel's following, in `namec`'s walk through the hook: restart at the process's root or the link's directory, the 40-link limit, and following or not at the last name.
3. The Linux ABI's calls: which follow the last name and which don't, `DT_LNK` and `S_IFLNK` from `DMSYMLINK`, and `ELOOP`.
4. The cases, the spec, and the h9build demo.

## Open issues

- **`..` after a link.** Plan 9 resolves `..` by the name walked (`cname`), Linux by the directory's real parent. After a relative link into another mount, the two can differ; this proposal takes Plan 9's, which is what every other walk in the namespace does.
- **Host paths in uncontained trees.** Whether an absolute target that doesn't resolve should be retried at `/mnt/term/<target>`, for projects with links to elsewhere on the host (see Rationale).
- **Cost.** Every link restarts a walk. Host trees walk locally, but a link-heavy tree on a remote 9P mount (a Nix store) could be slow; the mount index ([mount-index](mount-index.md)) may need to carry link targets.
