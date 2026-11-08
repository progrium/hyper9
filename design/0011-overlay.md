---
id: 11
slug: overlay
title: Copy-on-write overlay as the root's default
status: implemented
created: 2026-11-03
authors: [progrium]
depends: [6]
areas: [sandbox, cli, kern]
---
 
# Proposal: copy-on-write overlay as the root's default
 
Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>
 
## Abstract
 
Enforce `--write=overlay` and make it the default: [ephemeral-writes](0006-ephemeral-writes.md)'s copy-on-write device, `#O`, goes over the root, whatever kind of root it is, so writes to the root succeed inside the run and vanish when it ends. The cwd and `--writable` paths still write to the host, as under `scope`. The root tree on the host is never written unless it's a `--writable` path.
 
## Background
 
This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's capability table had a row for it:
 
| Capability | Mechanism |
| --- | --- |
| `fs.write.overlay` | A copy-on-write overlay device, shared with image-backed roots |
 
With it, the default profile's root row was to become: read-only underneath, with an ephemeral overlay, so writes succeed and vanish.
 
### h9 today
 
- **The root is read-only** in both profiles. A write to it fails with "permission denied", and installing into it needs `--writable "$H9ROOT"`, which writes the host tree.
- **`--write=overlay`** is accepted but not enforced: it falls back to `none`, the plan lists `fs.write.overlay` as `unenforced`, and `--strict` refuses it with exit 2.
- **Programs that write the root** fail. 9front programs expect a writable root, as on a 9front terminal: `$home` (`/usr/$user`, which a root tree doesn't have for the host user), `/sys/log`, `/lib/ndb/local` edits, `mk install` into `/$objtype/bin`, and `acme`'s dump file and `rio`'s settings under `$home`.
### What [ephemeral-writes](0006-ephemeral-writes.md) provides
 
- **`#O`,** a kernel device in `src/kern/devoverlay.c`: an instance is a tree in memory over a lower chan, with copy-up, whiteouts, and directory markers, and memory from the machine's page allocator, counted against `--memory`.
- **Binds:** `bind -c '#O' <target>` in a plan or namespace file makes a fresh instance over what `<target>` is at that point.
- **Its write modes:** `--write=ephemeral` overlays every path that `scope` would make writable, and a private `/tmp` replaces the host's temp directory. It leaves the root read-only, and says putting an overlay over the root is this proposal's.
## Proposal
 
### The write modes
 
| `--write` | Root | Cwd and `--writable` paths | `/tmp` |
| --- | --- | --- | --- |
| `none` | Read-only | Read-only (a conflict with `--writable`, as now) | Read-only |
| `scope` | Read-only | Write the host | Private, in memory |
| **`overlay`, the new default** | **Overlay: writes succeed and vanish** | Write the host | Private, in memory |
| `ephemeral` | Overlay | Overlays | Private, in memory |
 
So `overlay` is `scope` plus an overlay over the root, and `ephemeral` gains the root overlay too: under it, nothing reaches the host. The tight profile follows the same table, so its root is an overlay by default as well. Its cwd stays read-only under `overlay`, since that row is about host paths. `--profile=tight --write=scope` keeps the root read-only.
 
`--writable` on the root's own path, `--writable "$H9ROOT"`, still makes the root write the host, with no overlay, under `scope` and `overlay`, as it does today.
 
### The root overlay
 
The namespace builder makes the overlay right after the root itself, before every other bind:
 
```text
  bind '#U/Users/me/h9root' /                             ro
  bind -c '#O' /                                          eph  # /Users/me/h9root
  bind '#c' /dev
  ...
```
 
- **Any root:** the lower tree is whatever `/` is at that point: a host tree from `#U`, a [9P root](0013-9p-roots.md)'s mount, or an [image root](0014-image-roots.md)'s mount. So writes to a 9P root don't reach its server, and writes to an image root stay above its file server.
- **Binds over the root still work.** `/dev`, `/bin`, `/mnt/term/cwd`, and the rest are bound onto directories reached through the overlay. A directory that's only in the lower tree keeps its lower qid, and so does a directory marker, which is what a lower directory becomes when its children change, so the mount table keeps matching it. Only a copied-up file gets a new qid, and nothing is bound onto files of the root.
- **Writable paths inside the root** (`--writable "$H9ROOT"/usr/glenda`) are bound from `#U` over the overlay, so writes there go to the host, as the longest rule decides today.
- **`$home`.** If the root has no `/usr/$user`, the builder creates it in the overlay, so a guest's home directory exists and is writable, and vanishes with the run.
- **When memory runs out,** copy-up and creation in the root fail with "file system full" and change nothing, as [ephemeral-writes](0006-ephemeral-writes.md) specifies for every `#O` instance.
### The plan
 
- **Access:** the root's rule stays `allow_ro` for devfs, since `#O` never writes its lower tree, and prints as `eph`, as ephemeral-writes prints overlaid paths.
- **`enforces:`** gains `fs.write.overlay` under `overlay` and `ephemeral`. `Capability.enforceable` returns true for it, so `--strict --write=overlay` is accepted.
- **Caveats:**
  - "writes to the root are kept in memory, count against --memory, and are lost when the machine ends; when memory runs out they fail with \"file system full\""
  - For a 9P or image root, the "writes to the 9P root go to its server" caveat and the `--write=none` conflict of [9p-roots](0013-9p-roots.md) don't apply under `overlay` and `ephemeral`, since nothing reaches the server.
```text
$ h9 --print mk
profile:  default
enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope ipc.restrict kernel.isolation
limits:   write=overlay net=enable
namespace:
  bind '#U/Users/me/h9root' /                             ro
  bind -c '#O' /                                          eph  # /Users/me/h9root
  ...
access:
  eph  /Users/me/h9root
  rw   /Users/me/src/proj
caveats:
  - writes to the root are kept in memory, count against --memory, and are lost when the machine ends; when memory runs out they fail with "file system full"
  ...
```
 
### When writes are discarded
 
At the end of a run, if the guest changed the root outside `$home` and stderr is a terminal, h9 prints one line to stderr naming the top-level directories that changed:

```text
h9: changes to the root under /386, /lib were discarded (rerun with --writable "$H9ROOT" to keep them)
```

- **Only the guest's changes count.** The machine starts counting once the namespace is built, so the `$home` the builder creates isn't a change.
- **`$home` is left out.** acme's dump file and rio's settings land there in most interactive sessions, and a notice printed on every run would be ignored. The changes worth a notice are the ones that look like installs.
- **The library returns a summary, not a count.** The run's status gains a `RootChanges` value: whether the guest changed the root, and the top-level directories it changed, with `$home` reported separately. The CLI prints the notice from it. A later export proposal can add to the struct without changing the API's shape.

Scripts, whose stderr is rarely a terminal, don't see the notice.
 
## Rationale
 
**The root writable by default.** 9front programs are written for a terminal whose root is the user's own file server. A read-only root makes them fail in ways that look like h9 bugs: rc can't make `$home`, `mk install` fails, acme can't write its dump. An overlay gives every run a fresh, writable 9front, like a VM booted from a snapshot, while the host tree stays as installed.
 
**Writes vanish, rather than persist.** The root is shared by every run and every machine. Persisting one run's writes into it would make runs depend on each other's leftovers, and a guest could change the tools later runs use. `--writable "$H9ROOT"` stays the explicit way to install, and the end-of-run notice tells an interactive user when they've lost something.
 
**Cwd and `--writable` keep writing the host under `overlay`.** They're the paths the user granted, and writing them is the point of `scope`. `ephemeral` is there for runs that should change nothing on the host at all.
 
**`scope` kept as it is.** It's the right mode for a run that should fail loudly on a write to the root, such as a build check, and keeping it unchanged means `--write=scope` scripts see no difference.
 
**One overlay over `/`, before the other binds, for every kind of root.** Putting it there makes it the bottom layer everything else is bound over, so the device sees only the root's own files. Doing it for 9P and image roots as well gives one rule for what a write to `/` does, and takes the server's write policy out of the default plan's trust.
 
**Creating `$home` in the overlay.** The default environment sets `home=/usr/$user`, and root trees have only `/usr/glenda`. With a writable root the directory can exist without touching the host tree, which removes a common first failure.
 
**The tight profile takes the overlay too.** A profile decides how much of the host a guest reaches; `--write` decides what writes do. Tight's differences, a read-only cwd, a masked `#I`, and a timeout, all keep the guest away from the host, and the overlay never writes the host, so it doesn't weaken them. This is the reasoning [ephemeral-writes](0006-ephemeral-writes.md) uses for tight's cwd under `ephemeral` and for its private `/tmp`. Tight is also where a read-only root fails most: untrusted or one-off programs are the ones that try to write `$home` or `/sys/log`. `--write=scope` keeps a read-only root available in either profile, so the two settings stay independent.

**A notice only on a terminal.** Silent loss of `mk install` output is the cost of this default. A line on an interactive stderr is enough to catch it; anything more, such as a nonzero exit, would turn an ordinary run into a failure. It names the directories that changed so a user can tell an install from noise, and it says to rerun, since nothing from the finished run can be recovered.

**Not in this proposal: keeping a run's root changes.** Exporting them at exit is left to its own proposal, as [ephemeral-writes](0006-ephemeral-writes.md) leaves it. The `RootChanges` summary is where such an export would report what it saved, and the notice would become "changes saved to …".
 
**The cost, gated.** Every walk in the root goes through `#O`: a lookup in its memory tree, then the lower device. For a root nothing has written, that's one hash miss per path element. The proposal is gated on measuring it (Done when). If it costs too much, `#O` gets a fast path for directories with nothing in memory before this becomes the default.
 
## Compatibility
 
- **Default behaviour:** writes to the root succeed and vanish, where they failed with "permission denied". A script that tested writability of the root, or relied on a write failing, sees the difference; `--write=scope` restores the old behaviour.
- **`--write=overlay`** now does what it says, and `--strict --write=overlay` stops being a usage error. `--write=ephemeral` gains the root overlay.
- **`$home`** exists by default, in memory.
- **`--print` and `--ns`:** the root's overlay line and `eph` access, in ephemeral-writes' format, so saved plans replay.
- **The tight profile:** its root is an overlay too, where writes to it failed. `--write=scope` restores the old behaviour.
- **`Machine.Options`:** `Policy.write`'s default (null) now means `overlay`. The run's status gains a `RootChanges` summary.
- **CLI flags and exit codes:** unchanged.
- **Vendored tree:** unchanged.
## Security
 
- **The root on the host is never written** unless it's `--writable`. `#O` opens its lower tree read-only, and devfs's rule for the root stays read-only, so a write that reached devfs by another route would be refused.
- **Reads are still checked.** Lower lookups go through the lower device, so `--read-deny` and symlink resolution apply in the root as before. A whiteout can hide a file, never reveal one.
- **Memory is capped.** Copies and bookkeeping come from the machine's page allocator, under `--memory`.
- **Servers are protected too.** With a 9P or image root, the overlay keeps the guest's writes from the server or the image's file system.
- **Between machines:** each machine's overlay is its own instance, so machines in one host process never see each other's root changes.
## Done when
 
Integration cases tagged `[overlay]`:
 
- `test "a write to the root under the default profile succeeds and leaves the root tree unchanged [overlay]"`
- `test "mk install into the root works and leaves the root tree unchanged (demo) [overlay]"`: `cd /sys/src/cmd && mk cat.install`, then `/bin/cat` runs the new binary.
- `test "removing a root file hides it in the guest only [overlay]"`
- `test "$home exists and is writable when the root has no /usr/$user [overlay]"`
- `test "the cwd still writes the host under --write=overlay [overlay]"`
- `test "--write=scope keeps the root read-only [overlay]"`
- `test "--writable on the root writes the host, with no overlay [overlay]"`
- `test "--write=ephemeral overlays the root as well [overlay]"`
- `test "--strict --write=overlay is accepted [overlay]"`
- `test "--print output with the root overlay replays with --ns [overlay]"`
- `test "the tight profile's root is an overlay [overlay]"`
- `test "a write to the root fails with file system full when memory runs out [overlay]"`: under a small `--memory`, the write fails and the guest keeps running.
- `test "the discarded-changes notice is printed on a terminal and not otherwise [overlay]"`: it names the changed top-level directories.
- `test "changes only under $home, or only by the namespace builder, print no notice [overlay]"`
- With [9p-roots](0013-9p-roots.md) implemented, `test "a write to a 9P root under the default profile doesn't reach the server [overlay]"`.
Backend case: two machines in one process each see only their own root changes.
 
Measurement: the `[baseline]` suite and `zig build bench`, with and without the root overlay, recorded in DESIGN.md. The default changes only if the overlay costs less than 5% of the suite's run time.
 
Demo: `h9 --rc 'echo hi > /lib/x && cat /lib/x'` prints `hi`, and the root tree has no `/lib/x` afterwards.
 
## Implementation
 
1. With [ephemeral-writes](0006-ephemeral-writes.md) implemented: the root overlay under `--write=overlay` and `ephemeral` in `src/policy.zig`, after the root's bind or mount, with `eph` access, `enforces:`, caveats, and `--strict`.
2. `$home` in the overlay when the root lacks it.
3. The measurement, and a fast path in `#O` if it's needed.
4. `overlay` as the default of `Policy.write` in both profiles, the run status's `RootChanges` summary, and the CLI's notice.
5. README's sandbox table, and DESIGN.md: the capability table, the default profile's root row, the tight profile's paragraph, the CLI table's `--write` row, and the plan example. Set `status: implemented`.
 

## Updates

- 2026-11-07: Refinements made while implementing it:
  - The summary is `Machine.root_changes`, a `RootChanges` value set by each `run`, rather than a field of `Status`, which is a tagged union every embedder switches on. It holds whether the guest changed the root outside `$home`, the changed top-level names (up to 16, sorted, with a flag for more) and whether it changed `$home`. `#O` reports each create, copy-up, remove, and wstat to the machine once tracking starts (`h9_overlay_track`), after the namespace and any `--ns` replay are built.
  - For a 9P root the notice says to rerun with `--write=scope`, since `--writable "$H9ROOT"` names a host tree.
  - A bare `#O` over `/` used to take the root device under the mount as its lower tree (namec's `Atodir` stops before a mount point); `h9_overlay_newpath` now resolves the target through its mounts, so an overlay over a bind or mount point overlays what's bound there. This also fixes the manual's known issue for `#O` lines on `/mnt/term/cwd`.
  - Replaying `--print` output with the root overlay line into a machine whose namespace is already built put the builder's binds below it out of reach, since mount points are matched by device as well as qid. `findmount` now also matches an overlay's lower directory's mounts (only when a mount hash bucket has an entry with the same qid path), a small change to the vendored `chan.c`, and after a replay without a `cd` the cwd is set again, so it lands on the replayed binds.
  - The measurement (DESIGN.md, "The root overlay's cost"): on HVF the `[baseline]` suite takes 27.29 s with the root overlay and 27.05 s without (median of 3 runs each), under 1%, well inside the 5% gate; on the emulator, walk-heavy commands differ within noise. No fast path in `#O` was needed, and `overlay` is the default.
  - The `--strict` baseline case can no longer show a refusal: this build enforces every capability it knows.

