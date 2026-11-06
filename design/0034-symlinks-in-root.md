---
id: 34
slug: symlinks-in-root
title: Symlinks resolved inside a bound tree
status: draft
created: 2026-11-05
authors: [progrium]
depends: []
areas: [kern, sandbox]
---

# Proposal: Symlinks resolved inside a bound tree

## Abstract

A host tree bound into the namespace can be marked *contained*. In a contained tree, devfs resolves symlinks itself, relative to the tree's top, as `openat2`'s `RESOLVE_IN_ROOT` does: an absolute target starts at the tree's top, and `..` stops there. Linux root trees, container images and 9front trees with links then work as their authors meant, instead of having their absolute links point at the host or get hidden by the policy. The resolved host path is still checked against the plan's access rules. Containment is a property of the bind, so other binds keep today's behaviour.

## Background

devfs-posix follows a symlink with `stat`, so the host kernel resolves it against the host's `/` (DESIGN.md, Path resolution). h9 then checks the *resolved* host path against the plan's rules. A link that points outside the allowed paths is hidden, which is correct for a sandbox, but wrong for a tree whose links are meant to be read relative to itself:

- On Alpine, `/bin/ls` is a link to `/bin/busybox`. Bound as a Linux root, it resolves to the host's `/bin/busybox`, which is hidden, or on a Linux host with busybox installed, outside the tree and denied.
- Container image layers, extracted to a directory, are full of absolute links.
- `..` in a relative link can climb out of the tree into a host directory that happens to be allowed for another reason, and the guest sees a file it didn't expect.

The [Linux personality](0018-linux-personality.md) needs this for its Linux root, and [dotl](0022-dotl.md) resolves links in a .L mount by the same rule. Both proposals described the devfs change as part of themselves; it's here so it can be built, tested and reasoned about once.

devfs-posix and devfs-win32 are vendored, and already carry h9's sandbox hooks (`h9_fs_check`, `h9_fs_allow`).

## Proposal

### Contained binds

A bind of `#U` gets a containment flag. In the namespace, it's the attach spec: `#U!c/path/to/tree` attaches devfs at that path, contained. `--print` and namespace files show it in that form, so a printed plan replays with `--ns`. The policy uses it for:

- the [Linux personality](0018-linux-personality.md)'s Linux root,
- `--root DIR` when `--root-contained` is given, so 9front trees with links can opt in,
- nothing else by default.

### Resolution

For a contained attach, devfs keeps the tree's top as a host path and resolves each walk in h9's own code instead of with `stat`:

- Each component is looked up with `lstat` (on Windows, a reparse-point open). A non-link continues the walk.
- A link's target is read with `readlink`. An absolute target restarts at the tree's top. A relative one is relative to the link's directory.
- `..` at the top stays at the top.
- More than 40 links in one walk is "too many symbolic links".
- A link to a missing target is "file does not exist", in a walk and in a directory listing. A listing shows a link with its target's `Dir`, as `stat` would.
- The resolved host path is passed to `h9_fs_check`, so the access rules still decide, as today.
- On Windows, junctions and symlinks are both reparse points with a target; both are resolved this way. Other reparse points are refused.

The resolved path is kept on the chan, as today's `uif->path` is, so later operations act on it without resolving again. Create, remove and rename act on the final name, as today, after resolving its parent.

### For the Linux personality

devfs keeps the unresolved link target of the last component, so the Linux personality's `readlinkat` and `lstat`-style calls can report a link where Linux would. They read it through a leaf (`h9_fs_readlink`), not through a 9P message, since Plan 9 programs never see links.

## Rationale

**Resolving with `openat2(RESOLVE_IN_ROOT)`.** Linux 5.6 and later does exactly this in the kernel, atomically. macOS and Windows have nothing like it, and h9's sandbox has to work the same on every host. DESIGN.md also records why h9 moved from `RESOLVE_BENEATH` to a resolved-path check on every host. Using `openat2` where it exists is an optimisation for later, if the results match.

**`chroot` or a mount namespace on the host.** They need privileges h9 doesn't have, and don't exist on macOS or Windows.

**Copying or rewriting the tree's links.** Rewriting Alpine's links to be relative works for one tree, once. It doesn't help with trees the user brings, and it changes what they see.

**Containing every bind.** It would change the meaning of today's binds of the cwd and `--readable` paths, where users expect their host links to work as on the host, within the policy. So it's opt-in per bind.

**A flag in the attach spec, not a new bind flag.** The kernel's `bind` flags are 9front's, and namespace files are parsed as 9front's. The attach spec is devfs's own, so the flag stays inside devfs.

## Compatibility

- **New CLI flag** `--root-contained`.
- **Namespace files and `--print`** gain the `#U!c` attach form. Older h9 versions reject it with "bad attach spec".
- **Vendored tree:** devfs-posix and devfs-win32 call a resolver in `src/kern/fscheck.c` for contained attaches. Uncontained attaches take today's path unchanged.

## Security

- **Resolution never leaves the tree.** Absolute targets and `..` are anchored at the top, so no link, however written, names a path above it.
- **The access rules still decide.** The resolved path is checked by `h9_fs_check`, so a tree that's allowed only in part, or has `--read-deny` paths inside it, is still enforced.
- **Races.** A host process changing links inside the tree while the guest walks it can make a resolution land somewhere unexpected, but the result is checked, so it lands only on allowed paths. This is the caveat `--print` already lists.
- **Loops** are cut at 40 links.

## Done when

- `test "absolute symlink in a contained tree resolves inside it [symlinks-in-root]"`
- `test "symlink with .. stops at the top of a contained tree [symlinks-in-root]"`
- `test "symlink loop is too many symbolic links [symlinks-in-root]"`
- `test "contained tree still honours --read-deny [symlinks-in-root]"`
- `test "uncontained bind follows host symlinks as before [symlinks-in-root]"`
- `test "--print's #U!c bind replays with --ns [symlinks-in-root]"`

Demo: `h9 --root-contained --root ./tree-with-links ls -l /bin`.

## Implementation

1. The resolver in `src/kern/fscheck.c`, for POSIX, with unit tests on a temporary tree.
2. The `#U!c` attach spec in devfs-posix, `--print` and `newns` parsing, `--root-contained`.
3. The Windows resolver and devfs-win32.
4. `h9_fs_readlink`. DESIGN.md's Path resolution paragraph describes contained trees.

## Open issues

- **Hardlinks** inside a contained, writable tree can still reach host files outside it, as today's caveat says. Containment doesn't change that.
