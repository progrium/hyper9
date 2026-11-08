---
slug: overlay-export
title: Exporting a run's overlay changes
status: draft
created: 2026-11-07
authors: [progrium]
depends: [6]
areas: [sandbox, cli, kern]
---

# Proposal: exporting a run's overlay changes

## Abstract

Add `--export-changes FILE`: when the run ends, h9 writes everything its `#O` overlays hold (files created or changed, and names removed) to FILE as a tar archive in the OCI layer format. Entries are guest paths. Removed names become `.wh.` whiteouts, and replaced directories are marked opaque. Nothing else about the run changes: writes still land in memory, and the host tree under each overlay is still never written. The `Machine` API gets the same option as a writer.

This lets you keep what a run did without writing the host. You can read the archive, apply it yourself, or use it as a layer. It also replaces [overlay](0011-overlay.md)'s "changes to the root were discarded" notice with "changes saved to FILE" when the flag is given.

## Background

### h9 today

- **[ephemeral-writes](0006-ephemeral-writes.md)** added `#O` (`src/kern/devoverlay.c`). An instance is a tree in memory over a lower chan, made up of copies, whiteouts, and directory markers. `--write=ephemeral` puts one over the cwd and each `--writable` path, and every machine has one over `/tmp`.
- **[overlay](0011-overlay.md)** puts one over the root by default and adds a count of discarded root changes to the run's status, so the CLI can print a notice on a terminal.
- **Changes are lost at exit.** DESIGN.md says "Ephemeral changes can't be exported yet". An instance is freed when the last chan on it closes, which happens when the run's last process tears down its namespace. The only way to keep a change is to make its path `--writable`, which writes the host as the guest goes, with no review step and no undo.

### What people want from a run's changes

- **See what a run changed.** After a build, an install script, or an unknown program runs under `--write=ephemeral`, you want to know which files it created, changed, or removed.
- **Keep an install without letting the guest write the root.** For example, run `mk install` against the overlay, check the result, then apply it to `$H9ROOT` yourself.
- **Make a layer.** [image-roots](0014-image-roots.md) and container tooling think in layers, and the memory tree already *is* a layer: copies are the files the layer adds, whiteouts are its deletions, and directory markers are the directories it passes through.

ephemeral-writes said this already: "the memory tree … already is that diff, so the device keeps it walkable until the instance is freed. The export is its own proposal."

## Proposal

### The flag

`--export-changes FILE` writes the run's overlay changes to FILE, a host path, as a tar archive.

- **When FILE is opened:** FILE is created, or truncated, before the machine starts. A path that can't be opened for writing is a usage error (exit 2) and nothing runs. FILE can also be a pipe or a `/dev/fd/N` path. Truncating doesn't apply to those, and they're written as a stream.
- **No `-` for stdout.** The guest owns stdout, so an archive written there could be mixed with the guest's own output. To stream the archive, give a `/dev/fd/N` path (`--export-changes /dev/fd/3 3>&1 >/dev/null`) or a pipe, or use `Machine.Options.export_changes`.
- **When it's written:** after the run's last process exits, whether it exited normally, was killed, or timed out, and before the overlays are freed. A run with no changes writes an empty archive, which is just the end-of-archive blocks.
- **Combining with other flags:** it works with every `--write` mode that has overlays (`overlay`, `ephemeral`, and `scope`, which still overlays `/tmp`). Under `--write=none` there are no overlays, so the flag is a usage error. It also works with `--ns`.

### What's exported

- **Every overlay except `/tmp`.** That's the root's overlay under `overlay` and `ephemeral`, the cwd's and each `--writable` path's under `ephemeral`, and any instance a `--ns` file made with a bare `#O`. `/tmp` is left out: it's private scratch space with no host tree under it, and keeping it out keeps compiler temporaries and lock files out of the archive. `--export-changes` with `--export-tmp` includes it.
- **Paths are guest paths, relative to `/`.** A root change is `lib/x`, and a change in the cwd is `mnt/term/cwd/out/x`. Under the default `--write=overlay`, the cwd and `--writable` paths write the host and have no overlays, so the archive holds only root changes and applies to the root tree as it is (`tar -x -C "$H9ROOT"`). The namespace builder knows each instance's target, the guest path it bound the instance over. The exporter prefixes that target to every entry from the instance.
- **Entries are in instance order, then depth-first by name.** Instances come in the order the plan made them, so the root's always comes first. The output is deterministic, so two runs that make the same changes give byte-identical archives, apart from mtimes.

### The format

The archive is POSIX tar (pax), using the [OCI image layer](https://github.com/opencontainers/image-spec/blob/main/layer.md) conventions for changes:

| Node | Entry |
| --- | --- |
| Copy (file) | A regular file with the copy's data, mode, and mtime |
| Copy (directory) with nothing of that name in the lower tree | A directory with its own mode and mtime |
| Copy (directory) that replaced a lower name (removed, then created again) | A directory, followed by `<dir>/.wh..wh..opq`: an opaque directory, so nothing from the lower tree shows through |
| Whiteout | An empty file `<parent>/.wh.<name>` |
| Directory marker | A directory, with the mode and mtime of the snapshot taken when the marker was made, so parents exist before their children |

- **Ownership:** devfs shows every host file as owned by the guest's user, so entries carry uid and gid 0 and no user names. The guest's `uid` and `gid` strings aren't exported.
- **Names:** pax records carry any name longer than ustar allows. `#O` names can be up to 1023 bytes.
- **Mode bits:** the permission bits are exported. 9front's `DMAPPEND` and `DMEXCL` have no tar equivalent and are dropped, and the archive's header says so in a pax global record, `H9.dropped=append,excl`, when any were set.

### Names that can't be exported

A guest could create a file that's literally named `.wh.foo` or `.wh..wh..opq`, and an OCI tool would read it as a whiteout. The exporter leaves such files out and prints one line for each to stderr: "h9: export: skipped /path/.wh.foo: reserved name". The count of skipped names goes into the run status alongside the exported count. `.` and `..` can't occur, because `#O` refuses to create them, and the exporter checks for them too.

### The library

- **`Machine.Options.export_changes: ?*std.Io.Writer`.** When it's set, `run` writes the archive to it after the run's last process exits and before the run returns. An embedder can stream the archive anywhere: a file, a buffer, or a socket.
- **`Machine.Options.export_tmp: bool`.** This includes `/tmp`.
- **The run's status** reports how many entries were exported and how many names were skipped, next to [overlay](0011-overlay.md)'s count of discarded root changes. If writing to the writer fails, the run returns the guest's status anyway, and the status also carries the error, so a failed export never hides how the guest ended.

### Keeping instances alive until the export

The exporter needs each instance's memory tree and pages after the processes have gone. The namespace builder takes one extra reference on every instance it makes when an export was asked for, and drops it after the export. So the last process's namespace teardown no longer frees those instances. The extra reference keeps them alive until the exporter has walked them. The machine's pages are freed after that, as ephemeral-writes' last update requires.

A new C leaf in `devoverlay.c` walks an instance under its QLock and calls back into Zig for each entry:

```c
/* Calls fn once per memory node, depth-first by name; returns -1 with the error set if fn fails. */
int h9_overlay_walkchanges(int id, int (*fn)(void *arg, OvEntry *e), void *arg);
```

`OvEntry` gives the node's kind (copy, whiteout, or marker), its path relative to the instance, whether it's opaque, its `Dir`, and a read function for a copy's blocks. The tar is built in Zig, in a new `src/changes.zig`, so the C side knows nothing about the archive format.

If a machine is left `stuck` after a timeout, its processes still hold the namespace, so it isn't exported. The run's status says so, and the CLI prints "h9: export: machine is stuck, changes not exported".

### The CLI

- **[overlay](0011-overlay.md)'s notice:** with `--export-changes`, the end-of-run line becomes "h9: changes saved to FILE (N entries)". It's printed to a terminal only, as before. Without the flag, the discarded notice adds the option: "h9: changes to the root were discarded (--export-changes FILE saves them; --writable "$H9ROOT" keeps them)".
- **Errors:** if writing the archive fails, h9 prints "h9: export: <error>" and exits 125 when the guest itself succeeded. A failed guest's status stands, so scripts still see why the guest failed.
- **`--print`:** the plan gains `export: FILE` under `limits:`, and each exported overlay's namespace line gets `exp` after `eph`. `--ns` ignores that column, as it does other annotations.

```text
$ h9 --print --write=ephemeral --export-changes out.tar mk
profile:  default
enforces: env.scrub fs.read.scope fs.write.ephemeral fs.write.overlay fs.write.scope ipc.restrict kernel.isolation
limits:   write=ephemeral net=enable export=out.tar
namespace:
  bind '#U/Users/me/h9root' /                             ro
  bind -c '#O' /                                          eph exp  # /Users/me/h9root
  ...
  bind -c '#O' /mnt/term/cwd                              eph exp  # /Users/me/src/proj
  bind -c '#O' /tmp                                       eph      # /Users/me/h9root/tmp
...
```

## Rationale

**A file written by the host, not by the guest.** The guest only sees the merged tree. It can't tell a copied-up file from an unchanged one, and it can't see whiteouts at all. The device can, because its memory tree is the diff. Exporting from the host also means the guest never gets a host path to write to: the user picks FILE, and the guest only decides what goes in it.

**Tar, and the OCI layer format in particular.** Tar is the one archive format every host has a reader for, including Windows' `tar.exe`. Plain tar can't represent a deletion. OCI's `.wh.` whiteouts and opaque markers are the standard way to do it: Docker, Podman, `umoci`, and `crane` all read them, and they map one-to-one onto `#O`'s nodes. A layer h9 writes can be stacked by those tools, and [image-roots](0014-image-roots.md) can take one later.

**Rejected: writing a directory tree.** A plain directory is easy to browse, but it can't hold whiteouts unless it uses the same `.wh.` files. Writing many files on the host also means more ways to fail halfway, and it raises the question of what happens if the target directory already has files in it. An archive is one file, written in one pass.

**Rejected: a diff (`diff -r` output or a patch).** A diff can't carry binaries, modes, or empty directories. It's also only useful for text and for review, and it can't be applied as a layer.

**Rejected: exposing the upper tree to the guest, as `#O<n>/changes`.** The guest could then run its own `tar`. But 9P has no way to represent a whiteout or an opaque directory, so the guest would need a convention anyway, and the guest's tar would decide the format. This would also make a run's changes visible inside the run, which is a new thing for the guest to reach.

**Rejected: also applying an archive at the start of a run (`--import-changes`).** That would let one run continue where another left off without writing the host. It's useful, but it brings back the problem [overlay](0011-overlay.md) solves: runs that depend on each other's leftovers. It's also not needed for any of the uses in Background. It can be its own proposal, and the format here doesn't get in its way.

**Guest paths, one archive.** One archive keyed by guest path describes the run the way the guest saw it. It also stays unambiguous when overlays nest, for example a `--writable` path inside the cwd, because the inner overlay's entries carry the inner target's prefix. Under the default `--write=overlay`, only the root has an overlay that's exported, so the archive is the root's changes alone. Cwd entries, which carry `mnt/term/cwd/`, appear only under `--write=ephemeral`, and there the prefix is what tells them apart from root changes. Applying only the root's changes then takes a path filter (`tar -x -C "$H9ROOT" --exclude 'mnt/*'`).

**Rejected for now: one archive per overlay** (`--export-changes /=root.tar`). It would avoid that filter, but it needs a flag per overlay or a naming scheme for files written next to FILE. It can be added later without changing the single-file form, if `ephemeral` users need it.

**No `-` for stdout.** Writing the archive to stdout would mean promising that nothing else reaches stdout for the whole run, while the guest owns it. If anything did, the archive would be corrupted without any error. A `/dev/fd/N` path or a pipe streams the archive just as well on Unix, and the library takes any writer.

**`/tmp` left out by default.** Every machine has a `/tmp` overlay, and compilers, `mk`, and editors leave files there. It has no host tree under it, so there's nothing to apply its changes to. Including it would make most archives mostly noise.

**Export even when the guest fails or is killed.** A failed build or install is exactly the case where you want to see what it changed. The guest's status is reported unchanged next to the archive.

**Exit 125 only when the guest succeeded.** A run whose archive couldn't be written lost the thing it was asked to produce, so a script shouldn't see 0. But replacing a failed guest's status would hide the more important failure. 125 is already h9's "h9 itself failed" status.

**Dropping reserved names rather than escaping them.** OCI has no escape for a literal `.wh.` file name. Writing one would make the archive say something the guest didn't do, which is a deletion. Skipping it, with a message and a count, is honest and rare.

**Holding a reference, not changing when instances are freed.** The rule "the last close frees the instance" stays as it is. Export only adds one holder, and only when export was asked for. A run without the flag frees its overlays exactly as today.

## Compatibility

- **CLI:** two new flags, `--export-changes FILE` and `--export-tmp`. Exit codes are unchanged, except that 125 can now also mean a failed export.
- **`--print` and `--ns`:** a new `export=` limit and an `exp` column marker. `--ns` ignores both, so saved plans still replay.
- **`Machine.Options`:** two new fields, `export_changes` and `export_tmp`. Both default to off. The run status gains the exported and skipped counts and the export error. That's the same status change [overlay](0011-overlay.md) makes for its discarded count, so the two should land as one status shape.
- **Sandbox defaults:** unchanged. Nothing is exported unless asked.
- **Root tree and `third_party/`:** unchanged.

## Security

- **The guest gains no new reach.** It can't name, open, or see FILE. The archive is written by the host after the guest's processes have exited.
- **The guest controls the archive's contents,** and that's the point. Anyone extracting it should treat it like any untrusted layer. Names are guest names, which can't contain `/`, `.`, or `..`, and the exporter checks for those anyway. Whiteout-like names are skipped (see above), so an archive can't encode a deletion the guest didn't make through `#O`.
- **Size is bounded.** Everything exported is in the overlays' memory, which counts against `--memory`. So the archive can't be much larger than `--memory` plus tar headers.
- **Reads aren't widened.** The exporter only reads memory nodes. It never reads the lower tree, so a file hidden by `--read-deny` can't get into the archive. A directory marker's `Dir` is the snapshot devfs had already allowed the guest to stat.
- **Between machines:** each machine exports only its own instances. The walk leaf checks that the instance belongs to the calling machine's pool, as attaching does.

## Done when

Integration cases tagged `[overlay-export]`:

- `test "a new root file is exported at its guest path [overlay-export]"`
- `test "a removed root file is exported as a .wh. whiteout [overlay-export]"`
- `test "a directory removed and recreated is exported as opaque [overlay-export]"`
- `test "cwd changes under --write=ephemeral are exported under mnt/term/cwd [overlay-export]"`
- `test "/tmp is left out unless --export-tmp is given [overlay-export]"`
- `test "a run with no changes writes an empty archive [overlay-export]"`
- `test "changes are exported when the guest fails or times out [overlay-export]"`
- `test "a file named .wh.x is skipped with a message [overlay-export]"`
- `test "an unwritable export path is a usage error and nothing runs [overlay-export]"`
- `test "--export-changes with --write=none is a usage error [overlay-export]"`
- `test "the exported archive extracts with the host's tar [overlay-export]"`
- `test "two identical runs give the same entries in the same order [overlay-export]"`
- `test "--print shows the export limit and replays with --ns [overlay-export]"`

Backend case: two machines in one process, each exporting to its own writer, see only their own changes.

Demo: `h9 --export-changes out.tar --rc 'cd /sys/src/cmd && mk cat.install && rm /lib/ndb/common'`, then `tar -tvf out.tar` lists `386/bin/cat` (or the host's `$objtype`) and `lib/ndb/.wh.common`, while the root tree is unchanged.

## Implementation

1. `h9_overlay_walkchanges` in `src/kern/devoverlay.c`, with each node's opaque flag. The namespace builder records each instance's target and takes the extra reference when an export was asked for.
2. `src/changes.zig`: the pax/OCI writer and the reserved-name check. Unit tests on a hand-built tree.
3. `Machine.Options.export_changes` and `export_tmp`, and the export in `run` after the last process exits, then the status fields.
4. The CLI: `--export-changes`, `--export-tmp`, opening FILE early, exit 125, `--print`'s `export=` and `exp`, and the notice wording shared with [overlay](0011-overlay.md).
5. README's sandbox section, and DESIGN.md: the CLI table, "Ephemeral changes can't be exported yet" replaced, and the plan example. Set `status: implemented`.

