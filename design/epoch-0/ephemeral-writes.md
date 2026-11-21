---
issue: 6
slug: ephemeral-writes
title: Ephemeral writes and a private /tmp
status: implemented
created: 2026-11-03
authors: [progrium]
depends: []
areas: [sandbox, cli, kern]
branch: [main]
---

# Proposal: ephemeral writes and a private /tmp

Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Enforce `--write=ephemeral` with a copy-on-write overlay device, `#O`, in h9's own kernel code. Under it, every path the plan would make writable is an overlay: reads come from the host tree, while creates, writes, removes, and renames land in memory and are gone when the machine ends. The host tree is never written.

The same device over the root tree's empty `/tmp` gives every machine a private in-memory `/tmp`, replacing the host's temp directory. Overlay memory, data and bookkeeping both, counts against `--memory`. [overlay](overlay.md) can then put the same device over the root.

## Background

This was part of milestone M5 ("servers") in SPEC.md, before milestones became proposals ([#1](proposals.md)). SPEC.md's capability table had a row for it:

| Capability | Mechanism |
| --- | --- |
| `fs.write.ephemeral` | A ramfs union-bound with `bind -c` over writable paths; new files go to the ramfs and vanish on exit |

### h9 today

`--write` takes `none`, `scope`, `ephemeral`, or `overlay` (`src/policy.zig`):

- **`scope`** is the default. Paths the plan allows read-write are bound from `#U` with `MCREATE`: the cwd in the default profile, each `--writable` path, and `/tmp`. Writes go to the host.
- **`none`** binds everything read-only.
- **`ephemeral` and `overlay`** are accepted but not enforced. They fall back to `none`, are listed as `unenforced`, and `--strict` refuses them with exit 2.

`/tmp` depends on the profile. In the default profile it's the host's temp directory (`$TMPDIR`, `$TEMP`, or `/tmp`, from `hostTmp` in `src/main.zig`), bound read-write. In the tight profile it's the root tree's own `/tmp`, read-only. So a default-profile guest's temporary files land on the host, beside the host's own, and the tight profile has no writable scratch space at all.

### Why a ramfs union doesn't do it

A union `bind -c` of a ramfs before a host directory makes *new* files go to the ramfs, which is what the old row described. But in a Plan 9 union, everything else goes to the member where the name is found:

- **Opening an existing host file for writing** opens the host file. A writable host member is written, which defeats the point. A read-only host member gives "permission denied".
- **`remove` and `wstat`** of a host file go to the host member too.
- **`create` of a name that exists in the host member** truncates the host file, or fails on a read-only member.

So the old row's own example, `mk clean && mk`, would either write the host or fail at the first `rm` of an existing object file. Ephemeral writes need copy-on-write: a host file is copied into memory the first time it's changed, and a removed name is hidden by a whiteout.

A guest ramfs process has a second problem: h9 doesn't serve the `mount` syscall, and a 9P server per machine adds a process and round trips to every file operation.

## Proposal

### The overlay device, `#O`

`src/kern/devoverlay.c` is h9's own kernel device, in C, registered in `src/kern/devtab.c`. `O` is used by neither drawterm nor 9front.

**Instances.** An instance is a tree in memory, optionally above a lower directory. The namespace builder creates them from Zig while it builds the machine's namespace:

```c
/* Returns an instance number, or -1 with the error set. lower may be nil: a pure in-memory tree. */
int h9_overlay_new(Chan *lower);
```

It's then bound like any device with `bind '#O<n>' <target>`. Instances belong to the machine: a machine's binds are the only references to them. The last close of the last chan on an instance frees it, which happens at the latest when the machine's namespace is torn down at exit.

**In namespace files.** Instance numbers are per machine, so `--print` and `--ns` don't use them. In a namespace file, a `bind` whose source is `#O` with no number means: walk to the target, make a new instance with that chan as its lower tree, and bind the instance over the target with the line's flags. So `bind -c '#O' /tmp` puts a fresh overlay over whatever `/tmp` is at that point in the replay. No new directive is needed, and newns syntax is unchanged, as with the console's `<id>` placeholder.

**Nodes.** Each node in the memory tree is one of three things:
- **a copy:** a file or directory that exists in memory, with its own data and `Dir`
- **a whiteout:** a name removed from the lower tree
- **a directory marker:** a directory that exists in the lower tree and has changed children in memory, without copying the directory's contents

Walks look in memory first. A whiteout ends the walk with "file does not exist". A miss falls through to the lower tree through the lower chan's device, so the lower tree's own checks apply: devfs's `h9_fs_check`, `--read-deny`, and symlink resolution.

**Operations:**

| Operation | On a lower-only name | In memory |
| --- | --- | --- |
| `open` for reading | The lower file, opened through its device | The copy |
| `open` for writing | Copy up, then the copy | The copy |
| `open` with `OTRUNC` | A new, empty copy with the lower file's `Dir`, without reading the lower data | The copy, truncated |
| `create` | A new copy, replacing a whiteout if there is one | Fails as `create` does on an existing file, or truncates it as 9front does |
| `remove` | A whiteout | The copy is freed; a whiteout is left if the lower tree has the name |
| `wstat` of mode, mtime, or length | Copy up, then apply | Apply |
| `wstat` renaming a file | Copy up, rename the copy, and whiteout the old name | Rename; whiteout the old name if the lower tree has it |
| `wstat` renaming a directory | Refused with "permission denied" | Rename a copy; refused with "permission denied" for a directory marker, which stands for a lower directory |
| Directory read | The lower directory | Memory entries, then lower entries that aren't hidden by a whiteout or shadowed by a copy |

**Copy-up** reads the whole lower file through the lower chan into memory, then sets the copy's `Dir` from the lower file's. A process that already has the lower file open keeps reading the lower file. Copy-up is per name and happens once: later opens find the copy.

**Qids.** Lower files keep their lower qids. Copies get qids from the instance, with the high bit of `path` set so they can't collide with lower qids. A copy-up changes a file's qid, as a file replaced on 9front does.

**Errors.**
- Copy-up and creation fail with "file system full" when the machine's memory is used up, and the operation changes nothing.
- A lower tree that can't be read during copy-up fails the open with the lower device's error.

### Memory

A copy's data lives in pages from the machine's guest-physical page allocator, through a Zig leaf:

```c
void *h9_overlay_alloc(ulong n);
void h9_overlay_free(void *p, ulong n);
```

So the guest's own memory and its ephemeral files share one cap, `--memory`, exactly, as segments do.

**Blocks.** A copy's data is a list of page-sized blocks, not one contiguous buffer. Growing a file adds blocks and never moves its data, and a big file needs no big contiguous run of pages.

**Bookkeeping.** Nodes, names, and `Dir`s come from a small allocator inside the device that takes its pages from the same leaf, so they count against `--memory` too. There's no separate limit on names: a guest that creates empty files or whiteouts until memory runs out gets "file system full", as one that writes a big file does. A directory marker or whiteout costs a node and no data blocks.

### `--write=ephemeral`

`ephemeral` stops being unenforced.

- **What becomes an overlay:** every path the plan would bind read-write under `scope` is bound instead as an overlay over its `#U` chan. That's the cwd, and each `--writable` path, including a writable path inside a read-only cwd.
- **The tight profile:** under `ephemeral`, its cwd is an overlay as well. The reason it's read-only under `scope`, keeping the host's files safe from the guest, doesn't apply when nothing reaches the host.
- **The root** stays read-only unless it's a `--writable` path. Putting an overlay over the root by default is [overlay](overlay.md)'s.
- **Host access:** the overlaid host paths go into the plan's access rules as read-only, since the device never writes its lower tree. devfs then refuses any write that reaches it by another route.
- **`enforces:`** gains `fs.write.ephemeral`, and `--strict` accepts `ephemeral`.

### A private `/tmp`

With a root tree, `/tmp` is always a fresh `#O` instance over the root tree's own `/tmp`, writable, in both profiles and under both `scope` and `ephemeral`. That directory is empty in a root tree, so lookups that miss memory cost one walk of an empty directory. Under `--write=none` there's no overlay: `/tmp` is the root's read-only `/tmp`, as `none` means.

Putting the instance over the root's `/tmp` rather than over nothing makes every overlay in the plan the same kind, with a lower tree, so each prints and replays as `bind -c '#O' <target>`. An instance with no lower tree stays available to the namespace builder for runs without a root tree.

The host temp directory is no longer bound. `hostTmp` and `Policy.tmp` go away.

### The plan

- **Access:** a new kind, `eph`, beside `ro` and `rw`.
- **Namespace:** overlay binds print as `bind -c '#O' /mnt/term/cwd`, without an instance number, followed by `eph` and the overlaid host path in a trailing comment. `--ns` accepts the `eph` column as it does `ro` and `rw`, so `--print` output replays as written.
- **Caveats** for writable paths under `ephemeral`:
  - "ephemeral files count against --memory and are lost when the machine ends"
  - "a file opened for writing is copied into memory whole the first time"
  - The hardlink and `res.disk` caveats aren't listed for overlaid paths, since nothing reaches the host there.

```text
$ h9 --print --write=ephemeral --writable ./out
profile:  default
enforces: env.scrub fs.read.scope fs.write.ephemeral fs.write.scope ipc.restrict kernel.isolation
limits:   write=ephemeral net=enable
namespace:
  bind '#U/Users/me/h9root' /                             ro
  ...
  bind -c '#O' /mnt/term/cwd                              eph  # /Users/me/src/proj
  bind -c '#O' /mnt/term/cwd/out                          eph  # /Users/me/src/proj/out
  bind -c '#O' /tmp                                       eph  # /Users/me/h9root/tmp
access:
  ro   /Users/me/h9root
  eph  /Users/me/src/proj
  eph  /Users/me/src/proj/out
caveats:
  - ephemeral files count against --memory and are lost when the machine ends
  ...
```

## Rationale

**Copy-up, not a union.** A union sends every operation on an existing name to the member that has it, so it can't keep writes off the host without refusing them (see Background). A copy-up overlay is what Linux's overlayfs and Docker's layers do, for the same reason.

**A kernel device, not a guest ramfs.** A device needs no `mount` syscall, no process per machine, and no 9P round trip per operation. It can count its memory against the machine's cap through the page allocator, where a guest ramfs would count against it as ordinary heap but only as far as its own process can grow. It also gives [overlay](overlay.md) the device it needs for the root and image-backed roots.

**In C, in `src/kern/`.** A device is chans, qids, walks, and `waserror`, which is drawterm's world. Zig on the inside would cross the seam on every operation and break seam rule 1 at every lower-device call that can raise. h9's devproc and devhcons are C for the same reason, with Zig leaves for what Zig owns: here, the pages.

**Whole-file copy-up.** It's simple, and correct for the common writers: compilers, editors, `mk`, and tools that rewrite a file through a temporary. Those truncate or rewrite whole files anyway, and `OTRUNC` skips the copy entirely. The cost is that appending to a large host file copies all of it first, and a file bigger than the free memory can't be opened for writing. Block-level copy-on-write, filling each block from the lower file the first time it's touched, would make that cheap. Storing copies as blocks from the start means it can come later inside the device, without changing its interface or the plan.

**`/tmp` in memory for everyone.** Sharing the host's temp directory put guest files beside the host's: visible to other host programs, left behind after a crash, and outside the sandbox's view, since the plan had to allow the whole directory read-write. A private `/tmp` per machine keeps each run's scratch files its own, and makes the tight profile usable for programs that need scratch space.

**Charging `--memory`.** One cap for everything a machine holds in host memory keeps `--memory` the exact bound it already is. A separate `--tmp-size` would be one more number to choose, and a guest could still fill memory with a big ephemeral file under it.

**Bookkeeping against `--memory` too, not a node limit.** A fixed limit on names per instance would be a number with no right value: too low for a source tree's worth of object files, or too high to bound the heap on a small machine. Deriving it from `--memory` still leaves the heap outside the cap. Taking the device's nodes from the same pages as its data puts one bound on all of it, with one failure, "file system full", and one code path.

**Refusing directory renames of lower directories.** Renaming one means copying up or re-parenting its whole subtree, and whiteouts for every name under the old path. In 9front a rename only changes a name within its directory, and the tools h9 runs, compilers, `mk`, and editors, rename files, not directories. Refusing is honest. A file rename is supported. If a workload ever needs directory renames, the device can re-parent the subtree in memory with a whiteout at the old name, without changing its interface.

**`#O` without a number in namespace files, not a new directive.** An `overlay <path>` directive would be one more thing `--ns` parses that newns doesn't. A bare `#O` source keeps every line an ordinary `bind`, says what the line does, and follows the console's `<id>` placeholder, which already stands in for a per-machine name. Overlaying the chan the target walks to at that point in the replay is what the plan did when it was built.

**Not in this proposal: keeping the changes.** A run could export its changes at exit, as a tar or a diff, for a caller that wants to inspect them. The memory tree, copies, whiteouts, and directory markers, already is that diff, so the device keeps it walkable until the instance is freed. The export is its own proposal.

## Compatibility

- **`/tmp`** in the default profile is no longer the host's temp directory. Files a guest writes there don't appear on the host, and host files there are no longer visible to the guest. Scripts that passed files between host and guest through `/tmp` need a `--writable` path.
- **The tight profile** gains a writable, private `/tmp`.
- **`--write=ephemeral`** now does what it says, and `--strict --write=ephemeral` stops being a usage error.
- **`Machine.Options.policy`:** `Policy.tmp` is removed. Embedders that set it to share a host directory as `/tmp` should use a writable path instead.
- **`--print` and `--ns`:** new namespace lines and access kind, as above. A saved namespace with `#O` lines replays with `--ns`, making fresh instances. Namespace files that used `#O` before are unaffected, since nothing served it.
- **CLI flags and exit codes:** unchanged.
- **Vendored tree:** unchanged. The device and its leaves are h9's own files.

## Security

- **No host writes.** Under `ephemeral`, the overlaid host trees are opened through devfs read-only, and the access rules make them read-only too, so a write that somehow reached devfs would still be refused. Whiteouts, copies, and renames exist only in memory.
- **The policy still decides reads.** Every lower lookup and copy-up goes through the lower chan's device, so `--read-deny`, hidden paths, and symlink resolution apply to overlaid trees exactly as to bound ones. A whiteout can hide a host file from the guest, never reveal one.
- **Memory is capped.** Copy data comes from the machine's page allocator, so a guest can't use more host memory through files than `--memory` allows. A full overlay fails the write with an error rather than the machine. Nodes, names, and `Dir`s come from the same pages, so a guest can't grow the kernel heap by creating empty files or whiteouts either.
- **Isolation between machines.** Instances belong to one machine's namespace, so machines in one host process can't see each other's `/tmp` or ephemeral files.
- **Caveats that go away.** For overlaid paths, the hardlink and uncapped-writes caveats no longer apply, since nothing reaches the host. They stay for `--write=scope`.

## Done criteria

Integration cases tagged `[ephemeral-writes]`, using rc and the root tree's tools in a scratch cwd:

- [x] `test "a new file in an ephemeral cwd is readable and absent on the host afterwards [ephemeral-writes]"`
- [x] `test "writing an existing host file changes it in the guest only [ephemeral-writes]"`
- [x] `test "removing a host file hides it in the guest only [ephemeral-writes]"`
- [x] `test "rm then recreate, as mk clean && mk does, works [ephemeral-writes]"`
- [x] `test "a file rename moves it in the guest only [ephemeral-writes]"`
- [x] `test "renaming a host directory is refused [ephemeral-writes]"`
- [x] `test "ls of an overlaid directory lists each name once [ephemeral-writes]"`
- [x] `test "a --writable path inside a read-only cwd is ephemeral [ephemeral-writes]"`
- [x] `test "--read-deny still hides a path inside an ephemeral tree [ephemeral-writes]"`
- [x] `test "the tight profile's cwd is ephemeral under --write=ephemeral [ephemeral-writes]"`
- [x] `test "/tmp is private and writable in both profiles [ephemeral-writes]"`: a file written to `/tmp` isn't in the host's temp directory, and the tight profile can write there.
- [x] `test "/tmp is read-only under --write=none [ephemeral-writes]"`
- [x] `test "filling an overlay fails with file system full and the machine carries on [ephemeral-writes]"`, under `--memory 32m`
- [x] `test "creating empty files until memory runs out fails with file system full [ephemeral-writes]"`, under `--memory 32m`
- [x] `test "renaming a directory marker is refused [ephemeral-writes]"`: a host directory with a changed child can't be renamed.
- [x] `test "--strict accepts --write=ephemeral, and --print shows the overlays [ephemeral-writes]"`
- [x] `test "--print output with overlays replays with --ns [ephemeral-writes]"`: the replayed run's cwd and `/tmp` are writable and the host is unchanged.

Backend cases in `tests/backends.zig`: two machines in one host process each get their own `/tmp`, and a copy-up while another process has the lower file open leaves that reader on the old contents.

Demo: in a copy of a 9front source directory, `h9 --write=ephemeral --rc 'rm -f *.c && echo gone > x && ls'` lists only `x`, and afterwards the host directory is unchanged.

## Implementation

1. `src/kern/devoverlay.c` with in-memory instances only (no lower tree), the page leaves in `src/kern.zig`, block storage for copies, and the node allocator on the same pages.
2. Lower trees: walk, open, and directory-read fall-through, copy-up, whiteouts, `OTRUNC`, renames. `/tmp` as an instance over the root's `/tmp` in both profiles; remove `hostTmp` and `Policy.tmp`. The `/tmp` cases pass.
3. `--write=ephemeral` in `src/policy.zig`: overlay binds, the `eph` access kind, `enforces:`, caveats, `--print`, and `--strict`.
4. `--ns`: the `eph` column in `src/newns.zig`, and a bare `#O` source in the replay in `src/machine.zig`. The `ephemeral-writes` cases pass.
5. README's sandbox table and `--ns` notes, and SPEC.md: the capability table, the default profile's `/tmp` row, and the tight profile's paragraph, `devoverlay.c` in the kernel's "Added by us" table, and the CLI table's `--write` row. Set `status: implemented`.

## Updates

- 2026-11-05: Refinements made while implementing it:
  - The page leaves take the machine's pool explicitly: `h9_overlay_alloc(void *pool, ulong n)` and `h9_overlay_free(void *pool, void *p, ulong n)`, with `h9_overlay_pool()` giving the calling thread's. An instance records its pool when it's made, because its last chan can be closed on any of the machine's threads. The pool also tells machines apart: attaching `#O<n>` from another machine fails with "file does not exist".
  - Zig makes instances with `h9_overlay_newpath(path)`, which resolves the lower directory with `namec` and reports errors as the `sys*` wrappers do, and frees one that's never attached with `h9_overlay_drop(n)`. The namespace builder resolves each overlay's lower tree from `#U<host path>`, the path in the plan's comment; a namespace file's bare `#O` overlays its target, as proposed.
  - Copies, and directories in memory, are checked by their owner permission bits, as devfs presents every host file as the guest's own: a file without write permission can't be opened for writing, and creating, removing, or renaming needs write permission on the directory.
  - A file in memory is limited to about 1 GiB (8 blocks in the node and two levels of index pages), and a name to 1023 bytes.
  - A directory with more than 64 entries keeps a hash table of them in host memory, so filling `/tmp` with empty files isn't quadratic.
  - A process closes its fds and namespace before it tells the machine it's done, so an overlay's last chan is closed while the machine's pages are still there.
  - HVF allows one VM per host process, so in the two-machine backend case the second machine is always the emulator.
