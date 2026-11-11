---
issue: 102
slug: recursive-unions
title: Recursive unions and root layers
status: proposed
created: 2026-11-08
authors: [progrium]
depends: [overlay, linux-personality]
areas: [kern, cli, sandbox]
---

# Proposal: Recursive unions and root layers

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Add recursive unions: a union directory whose members are merged at every depth, not only at the bind point, as Wanix's namespaces do. They're `#O` instances with several lower trees instead of one, so they reuse the overlay's walk, directory merging, and memory accounting, and need no change to the vendored `chan.c`. A new `bind -r` flag in h9's namespace syntax makes and extends them, a forked guest `bind` does the same inside the machine, and `/proc/n/ns` prints them as `bind -r` lines, so `--print` and `ns` output replays. A new repeatable `--layer DIR` stacks trees over a root, in the 9front view or the Linux view, and `#Oroot` and `#Olinux` name the merged stacks without the namespace's other binds, so `h9 --root base --layer app --rc 'cd ''#Oroot'' && tar cf /fd/1 .'` flattens trees into one archive.

## Background

### Plan 9 unions are one level deep

A union directory is a mount head with several members. A walk from it tries each member for the next name and takes the first that has it (`third_party/drawterm/kern/chan.c`, `walk`, the loop after `ewalk` fails). From then on the walk is in that one member's tree. So after `bind -a /a /` and `bind -a /b /`, `/bin` is `/a/bin` if `/a` has one, and `/b/bin` is hidden, however different the two are. Only a directory read of the union point itself (`unionread`) sees every member.

h9 has worked around this more than once:

- **[linux-net](linux-net.md)** wanted `/etc/resolv.conf` in an Alpine root without shadowing the rest of `/etc`, and noted that "Plan 9 unions don't merge below the top". devlinux serves a separate `#λetc` bound after `/etc`.
- **[builtin-root](builtin-root.md)** layers the built-in commands on `/bin` only, rejecting a union at `/` because its empty mount points and `rcmain` would shadow or mix with the root's at the top level.
- **[ephemeral-writes](ephemeral-writes.md)** explains why a ramfs union can't keep writes off the host, and built `#O`'s copy-up instead.

### Wanix's recursive unions

Wanix (`fs/vfs/vfs.go` and `fs/bind/table.go` in tractordev/wanix) keeps a table of bind points, each with an ordered list of members. Every bind point with more than one member is recursive, with no flag:

- **Lookup.** At any path under the bind point, each member is checked at the same relative path. If the first member that has the name has a file, that file is the result. If it has a directory, the result is a directory listing every member's directory by that name, with names deduplicated and sorted.
- **Writes.** Creates and mkdirs go to the first member whose parent directory exists. A write, remove, or rename goes to the member that holds the name, so removing a name from an upper member uncovers a lower member's copy. There are no whiteouts.
- **Order.** Wanix's default placement is `after`, and `after` puts the new member *first*, so the newest bind wins (`vfs_test.go`, the `test/file.txt` cases). That's the reverse of Plan 9's `bind -a`, which a translation between the two has to account for.
- **Deep binds.** A bind to a path that doesn't exist makes its parents appear as synthesized directories. That's a separate feature, and not part of this proposal.

### `#O` today

`src/kern/devoverlay.c` serves numbered instances. Each is a tree in memory over at most one lower directory, a chan held from when the instance was made. Walks look in memory first and fall through to the lower tree with device walks, so mounts inside the lower tree aren't crossed. The memory tree holds copies, whiteouts, directory markers, and symbolic links, from the machine's pages, counted against `--memory`. An attach checks that the instance belongs to the caller's machine.

Only the namespace builder makes instances. A plan or `--ns` line `bind -c '#O' PATH` makes a fresh instance over whatever `PATH` is at that point (`h9_overlay_newpath`) and binds `#O<n>` over it. A bare `#O` attach from a guest fails.

### Roots today

`--root` may be given twice, one 9front tree and one Linux tree, told apart by their contents ([linux-personality](linux-personality.md)). A later `--root` of a kind replaces an earlier one. The 9front tree is `/`, with an `#O` over it under `--write=overlay`. The Linux view is `#λ`, devlinux's own directories, with the Linux tree unioned after it and its own `#O`. A 9front process doesn't see the Linux tree unless it walks `'#λ'`. A Linux process sees the 9front root at `/9`.

The plan prints the Linux tree's overlay as `bind -a -c '#O' '#λ'`, with the Linux tree's host path only in the trailing comment. Replaying that line with `--ns` makes a fresh overlay over what `#λ` is at that point, devlinux's root, so a saved plan with a Linux root replays without the Linux tree (`src/machine.zig`, `replayNamespace`).

## Proposal

### Union instances

An `#O` instance gains an ordered list of **members**, lower directories, in place of its one lower, and a **mode**:

| Mode | Memory tree | Made by |
| --- | --- | --- |
| `cow` | Yes: writes are copied up and vanish | `bind -c '#O' PATH`, as today; one member |
| `union` | No: writes go to a member, or fail | `bind -r` |

`bind -c '#O'` on a union's target makes a `cow` instance over the union, as over anything else. A `cow` instance over a named union (see Named instances) takes the union's members as its own, so a layered root with a copy-on-write top is one instance, not two.

The rules, at any path under the instance's root:

- **Walk.** Each member is walked to the same relative path, in order. The first member that has the name decides what it is. A file is that member's file. A directory is a merged directory over every member that has a directory by that name, in member order; members with a non-directory by that name are skipped for it. Walks are device walks, as `#O`'s are now: a member is its tree, not the mounts on it. Mounts made on the instance's own paths work as on any directory.
- **Multi-element walks.** A walk of several names sends each member the remaining names in one device walk, and merges by depth from the qids it returns, so a 9P member costs one round trip per walk, not one per name.
- **Directory reads.** Each member's directory is read in order, and a name is listed once, with the first member's entry. Like `#O`'s merged reads now, the snapshot is taken at open and counted against `--memory`.
- **Qids.** Two members' files can have equal qid paths. The instance maps each (member, qid path) to a qid of its own the first time it's seen, in a table counted against `--memory`; a merged directory takes its first member's mapped qid. `stat` reports the mapped qid and otherwise the member's Dir.
- **Writes, `union` mode.** Opening for writing, truncating, `wstat`, and `remove` act on the member that holds the file. Removing uncovers a lower member's copy, as in Wanix. A create goes to the first member marked for creation (`-c` on its `bind -r`) that has the parent directory; with none, it fails with "mounted directory forbids creation", as a Plan 9 union without `MCREATE` does. A rename is a `wstat` of the name, so it stays within the member that holds the file. The member's own device decides whether the write is allowed: a read-only `#U` member stays read-only.
- **Writes, `cow` mode.** As `#O` now: copy-up from whichever member holds the file, and whiteouts that hide every member's copy.
- **`..`** is resolved from the chan's path, as `#O` does now.
- **Limits.** At most 64 members per instance. Instances count against `#O`'s existing limit of 256.

### Named instances

The attach spec `#O<n>` names an instance by number, as now. A spec of letters names an instance the namespace builder made for the machine: `#Oroot` is the 9front root's stack, and `#Olinux` is the Linux root's. A named instance lives until the machine ends. Its root holds only its members' trees, with none of the namespace's binds, which is what 9front's `/root` is for.

### `bind -r`

h9's namespace syntax (`src/newns.zig`, `--ns`, and `--print`) gains `-r`:

| Line | Means |
| --- | --- |
| `bind -r new old` | `old` becomes a fresh union of `new` alone |
| `bind -r -b new old` | `new` goes first in the union at `old` |
| `bind -r -a new old` | `new` goes last in the union at `old` |
| `bind -r -c ...` | The member takes creates |
| `bind -c '#O' old` | A `cow` overlay over `old`, as today |

With `-a` or `-b`, if `old`'s top mount is already a union instance, `new` is added to it. Otherwise a union is made of `new` and what `old` is now, and bound over `old` with `MREPL`. If `old` is a Plan 9 union, each of its mount head's members becomes a member, in order. If `old` is `#O<name>`, the named instance is made or extended, and nothing is bound in the namespace.

Every line names its sources by path, never by instance number, so `--print` output replays.

### Guests

- **The control tree.** A bare `#O` attach, which fails today, serves `clone`. Opening it makes a `union` instance owned by the caller's machine; reading it gives the instance number; and writing messages to it changes the instance: `add [-a|-b] [-c] PATH`, `del PATH`, and `cow`. The kernel resolves each path with `namec` in the writer's namespace, so it reaches only what the writer can already reach. An instance that is never attached is freed when its `clone` fd closes.
- **`unionbind`.** A C function in h9's guest sources, `int unionbind(char *new, char *old, int flag)`, does the `bind -r` steps above with `clone` and `bind`. Anyone patching libauth's `newns()` for `-r` can call it from a `case 'r'`.
- **`bind`.** A fork of 9front's `bind(1)` that accepts `-r` and calls `unionbind`, and is otherwise 9front's own. It's built into `#H`, and the plan binds `#H/over`, which holds only it, before `/bin`, so it takes precedence over the root's `bind`. `--no-guest-tools` leaves it out.
- **`/proc/n/ns`.** devproc (`src/kern/devproc.c`) prints a mount of a union instance as the `bind -r` lines that make it, and a named instance's members as `bind -r` lines on `'#O<name>'`, so stock `ns` prints a namespace that `--ns` replays.

9front's libauth `newns()` isn't changed. `auth/newns`, `login`, `cpu` and `rcpu` servers, and `listen`'s services skip or misread `-r` lines in `/lib/namespace`. The manual says `-r` belongs in `--ns` files, not `/lib/namespace`.

### `--layer`

`--layer DIR`, repeatable, stacks a host directory over the root given by the most recent `--root` before it, or over the 9front root when no `--root` comes before it. Later layers go on top, as in a Dockerfile. With layers, the 9front root is built as the named stack and bound at `/`:

```text
  bind -r '#U/home/me/base' '#Oroot'                       ro
  bind -r -b '#U/home/me/app' '#Oroot'                     ro  # --layer
  bind -r -b '#U/home/me/config' '#Oroot'                  ro  # --layer
  bind -c '#O' '#Oroot'                                    eph
  bind '#Oroot' /
```

A 9P or WebSocket root is mounted on `'#Oroot'` as its first member instead. Without layers, the 9front root's plan lines don't change.

The Linux tree is always built as `#Olinux`, with or without layers, and unioned after devlinux:

```text
  bind -r '#U!c/home/me/alpine' '#Olinux'                  ro
  bind -r -b '#U/home/me/etcfix' '#Olinux'                 ro  # --layer
  bind -c '#O' '#Olinux'                                   eph
  bind -a '#Olinux' '#λ'
```

The join of `#Olinux` to `#λ` stays a plain union, so the Linux tree's `/dev`, `/proc`, and `/sys` never merge with devlinux's. Since every lower tree is a bind line, this also makes a Linux root's plan replay.

Each layer gets the root's access: `ro` under `--write=none` and `scope`, under the overlay otherwise. A `--writable` layer is a member with `-c`, written through. Under `--write=scope` and `none`, the `bind -c '#O'` line is left out, and the stack is a read-only union.

The views meet as they do now. A Linux process's `/9` is the 9front root as built, layers and overlay included. A 9front process sees the layered Linux tree at `'#λ'` or `'#Olinux'`. `/tmp` and `/mnt/term` are shared and not layered.

### Machine API

`Machine.Options.layers: []const Layer`, each a host path and which root it's over (`.plan9` or `.linux`). Empty by default.

## Rationale

**In `#O`, not in `chan.c`.** A mount flag that made `walk` keep union state below the bind point is the most Plan 9 form, and would cross mounts inside members. But every directory reached under a union would need its member list on the Chan, through `cclone`, `cclose`, `..`, `unionread`, and `createdir`. That's a rewrite of the vendored kernel's hottest and most delicate path, on every walk, against AGENTS.md's guidance to keep vendor changes minimal. `#O` already has the walk-through, the merged directory read, the qid and memory handling, and the per-machine checks. A union is the same device with a list.

**Not a userspace file server.** A 9P server that merges trees, like kvik's unionfs for 9front, needs no kernel change. But each operation goes through devmnt, a pipe, a scheduled guest process, and that process's own syscalls to the members. Exec and directory listings, which unions are mostly for, would pay that on the emulator and in the browser host, where per-operation cost already dominates.

**A flag, not Wanix's always-recursive unions.** 9front's own namespace relies on one-level unions: `/dev` is `#c` with h9's console before it, and `/bin` is several trees. Making every union recursive would change what existing namespace files mean.

**`union` mode has no whiteouts.** It's the Wanix and Plan 9 behaviour: a union sends each operation to the member that holds the name. Hiding a lower file is what `cow` mode is for, and a `cow` instance over a union is one `bind -c '#O'` line.

**Creates need `-c`.** Wanix creates in the first member with the parent directory. Requiring `-c` keeps a union read-only by default, as Plan 9's `MCREATE` does, so adding a layer never makes the host writable.

**`--layer`, not a repeated `--root`.** `--root` is told apart by its contents, and a layer holding only `etc/resolv.conf` looks like neither kind. A separate flag keeps `--root` meaning the whole tree, and a layer never has to look like one.

**Named instances.** The Linux tree needs a place to be assembled before it's unioned after devlinux, and flattening needs the stack without the namespace's binds. A name in `#O` gives both without a mount point in the root tree, which a bare layer or base may not have.

**A forked `bind`, not a new command.** `bind -r` is what people will type, matching the plan. The fork is backward compatible by construction: without `-r` it's 9front's code.

**libauth left alone.** Every program that calls `newns()` links it statically, so patching it means relinking them all, for the rare case of a cpu server inside h9 reading `-r` from `/lib/namespace`. `unionbind` keeps that patch small for anyone who needs it.

## Compatibility

- **CLI:** new `--layer`. Without it, nothing changes for the 9front root.
- **`--print`:** a Linux root's plan changes from `bind -a -c '#O' '#λ'` with its path in a comment to the `#Olinux` lines above, which replay. New `-r` lines and named specs with `--layer`, and the `#H/over` bind.
- **`--ns`:** accepts `-r` and named `#O` specs. Files that worked before mean the same.
- **`Machine.Options`:** new `layers`, empty by default.
- **Guests:** a bare `#O` attach serves the control tree instead of failing. `/bin/bind` is h9's fork, which behaves as 9front's without `-r`. `ns` prints `bind -r` lines for unions.
- **`third_party/`:** no change.

## Security

- **What a guest can newly reach:** nothing. `add` resolves paths in the writer's own namespace, so a member is a tree the guest could already walk, and every walk and write into a member goes through the member's device, including `#U`'s access checks.
- **Writes:** a `union` instance writes only to members marked `-c`, and only where their device allows it. `--layer` members are read-only unless `--writable`.
- **Memory:** qid tables and merged directory snapshots come from the machine's pages, as `#O`'s memory does, so a guest that makes many instances or huge directories runs into `--memory`. The 256-instance and 64-member limits bound the host-side tables.
- **Other machines:** an instance belongs to the machine that made it, as now; `clone` makes it in the opener's machine, and attaching another machine's instance fails.

## Done criteria

```
h9 --root ~/9front --layer ./patches rc -c 'cat /lib/ndb/local'
h9 --root alpine --layer ./etcfix sh -c 'cat /etc/resolv.conf; ls /etc | wc -l'
h9 --builtin=before --root ./base --layer ./app --layer ./config --rc 'cd ''#Oroot'' && tar cf /fd/1 .' > merged.tar
h9 --rc 'mkdir /tmp/m; bind -r /mnt/term/cwd/a /tmp/m; bind -r -b /mnt/term/cwd/b /tmp/m; ls /tmp/m/bin'
```

Integration cases:

- [ ] `test "bind -r merges directories below the bind point [recursive-unions]"`
- [ ] `test "bind -r: the first member's file wins at any depth [recursive-unions]"`
- [ ] `test "bind -r: creates go to the first -c member with the parent [recursive-unions]"`
- [ ] `test "bind -r: removing an upper file uncovers the lower one [recursive-unions]"`
- [ ] `test "bind -c '#O' over a union copies up and whites out [recursive-unions]"`
- [ ] `test "--layer stacks over the 9front root [recursive-unions]"`
- [ ] `test "--layer stacks over the Linux root, and /dev stays devlinux's [recursive-unions]"`
- [ ] `test "#Oroot holds the stack without the namespace's binds [recursive-unions]"`
- [ ] `test "--print with --layer and a Linux root replays with --ns [recursive-unions]"`
- [ ] `test "ns prints unions as bind -r lines that replay [recursive-unions]"`
- [ ] `test "a guest can't attach another machine's union [recursive-unions]"`

## Implementation

1. `#O` members: the lower becomes a list, walks and merged reads go across it, the qid table, and `union` mode's write routing. Kernel tests in `src/kern.zig` beside the existing `#O` ones.
2. Named instances, `bind -r` in `newns.zig` and the machine's replay, and the Linux root as `#Olinux`, which fixes its replay.
3. `--layer` and `Machine.Options.layers`, and the plan lines for both views.
4. The control tree, `unionbind`, the forked `bind` in `#H/over`, and devproc's `bind -r` lines.
5. MANUAL and README: unions in the namespaces chapter, `--layer`, and the `/lib/namespace` caveat. SPEC.md once built.

## Open issues

- **`del` and `unmount`.** `unmount new old` on a union removes the whole bind, since the kernel sees one mount of the instance. Should the forked `unmount` call `del` when `new` is a member, so one layer can be dropped?
- **Layers from 9P servers.** `--layer` takes host directories. Dial strings and `wss://` URLs, as `--root` takes, would let a layer be remote.
- **Mount points in bare trees.** A base tree without `/dev`, `/tmp`, or `/mnt` can't take the plan's binds onto them. The built-in root, layered last at `/`, could supply empty mount points. That's [builtin-root](builtin-root.md)'s `--builtin=after` extended from `/bin` to the whole tree, which this proposal makes possible but doesn't do.
- **`#Oroot` without layers.** Should the 9front root always be built as `#Oroot`, so flattening and `/root`-style access work without `--layer`, at the cost of changing every plan's first lines?
- **`#H/over` precedence.** Binding h9's `bind` before the root's `/bin` is the first time h9 shadows a root command. It may want its own flag, or to be part of `--builtin=before`.
