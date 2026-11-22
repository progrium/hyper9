---
slug: overlay-export
title: Exporting a run's overlay changes
status: draft
created: 2026-11-07
authors: [progrium]
depends: [ephemeral-writes, mounts, linux-symlinks, linux-fifo]
areas: [sandbox, cli, kern, api, web]
---

# Proposal: exporting a run's overlay changes

## Abstract

Add `--export-changes FILE[:DST]`, a repeatable flag that writes the changes held by the overlay at DST to FILE when the run ends, as a tar archive in the OCI layer format. DST is named the way the mount flags name it: `/` (the default) and `#L` are the two stacks' overlays, and any other DST is an `eph` mount, `--tmp`, the cwd, or a path under one of them. Entries are relative to DST, so the archive applies to the tree that was mounted there, and `--archive FILE:DST` mounts it again in a later run. `--archive` learns the OCI whiteouts it needs for that: on a stack, a `.wh.` entry hides the name in the members below, and an opaque directory hides them all. Together the two flags make a run a layer, so a build can go step by step as a Dockerfile does, with each step's layer kept on the host and nothing in the host trees written. The `Machine` API and the browser host get the same thing as writers and byte arrays.

## Background

### h9 today

- **[ephemeral-writes](epoch-0/ephemeral-writes.md)** added `#O` (`src/kern/devoverlay.c`). A `cow` instance is a tree in memory over a lower chan, made of copies, whiteouts, and directory markers, and since [linux-symlinks](linux-symlinks.md) and [linux-fifo](linux-fifo.md) also symbolic links and FIFOs. Renames within an instance, across directories too, are moves in that tree.
- **[mounts](mounts.md)** made every tree a mount flag with a destination. `/` and `#L` are stacks, `#Oroot` and `#Olinux`, whose members are merged at every depth. A stack's write mode comes from `--write`: under `overlay` and `ephemeral` a `cow` instance goes over the whole stack (`bind -c '#O' '#Oroot'`), and a member marked `rw` takes the writes instead, with no overlay. Off the stacks, a mount is `ro` unless it says `rw` or `eph`, `--tmp DST` is an empty instance, and `/tmp` always has an overlay.
- **`--archive FILE[:DST]`** unpacks a tar, a gzipped tar, or an `.h9a` into an instance with no lower tree, which joins a stack as a member or is bound at DST. It reads every entry as a file, so an OCI layer's `.wh.` whiteouts come out as empty files with those names.
- **Changes are lost at exit.** An instance is freed when the last chan on it closes, at the run's teardown. [overlay](epoch-0/overlay.md)'s notice says "changes to the root under … were discarded" and suggests `rw` on the root, which writes the host as the guest goes, with no review and no undo.

### What people want from a run's changes

- **Build in layers.** A tool that builds an app from a runtime, its dependencies, and its source wants each step's output as its own layer, so a step whose inputs haven't changed is skipped and its layer reused. Today the only way to keep a step's output is an `rw` member, which writes a host directory as the guest goes. A stack with an `rw` member has no overlay, so a rename across directories there is a union's, which answers `EXDEV`, and package managers that make files in a staging directory and rename them into place fall back to copying or fail.
- **See what a run changed.** After a build, an install script, or an unknown program, you want to know which files it created, changed, or removed.
- **Keep an install without letting the guest write the tree.** Run `apk add` or `mk install` against the overlay, check the result, then apply it to the host tree yourself.

ephemeral-writes said this already: "the memory tree … already is that diff, so the device keeps it walkable until the instance is freed. The export is its own proposal."

## Proposal

### The flag

`--export-changes FILE[:DST]` writes the changes in the overlay at DST to FILE, a host path. It's parsed as the mount flags are: DST starts at the last `:` followed by `/` or `#`, a drive letter's `:` isn't a separator, and with no DST it's `/`. So it reads as `--archive` does, with the data going the other way:

```sh
h9 --dir ./alpine:#L --export-changes deps.tar:#L sh -c 'apk add python3'
h9 --dir ./alpine:#L --archive deps.tar:#L --export-changes app.tar:#L sh -c 'pip install -r req.txt'
h9 --dir ./alpine:#L --archive deps.tar:#L --archive app.tar:#L python3 /app/main.py
```

- **Repeatable,** once per DST. Two with the same DST, or two whose DSTs are in one instance with one under the other, are a usage error (exit 2). `/` and `/tmp` are different instances, so both can be exported.
- **FILE** is created, or truncated, before the machine starts, and one that can't be opened for writing is a usage error and nothing runs. A pipe or a `/dev/fd/N` path is written as a stream. A FILE ending in `.gz` or `.tgz` is gzipped. There's no `-` for stdout, which the guest owns.
- **When it's written:** after the run's last process exits, whether it exited, was killed, or timed out, and before the instances are freed. A run with no changes at DST writes an empty archive.

### Destinations

DST names a place in the plan, as a mount's DST does, and the plan decides which instance it is:

| DST | The instance |
| --- | --- |
| `/` | The root stack's overlay, `bind -c '#O' '#Oroot'` |
| `#L` | The Linux stack's overlay, `bind -c '#O' '#Olinux'` |
| `/tmp` | The machine's `/tmp` overlay |
| Another mount's DST | That mount's instance, when it's `eph`, `--tmp`, or `--archive` off a stack. Under `--write=ephemeral` this includes `/mnt/term/cwd` and each `--writable` path's place under `/mnt/term`. |
| A path under any of those | The same instance, with only the entries under that path, such as `#L/etc` or `/usr/glenda/lib` |

A DST that resolves to no instance is a usage error naming the reason: "--export-changes deps.tar:#L: #L has no overlay (its member ./alpine is rw)", or "… /n/fs is a 9P mount". An export is of one instance only, so `/`'s doesn't include `/tmp` or the cwd, which are bound over it, and nothing is left out by a filter.

### What's in the archive

The archive is POSIX tar (pax), with the [OCI image layer](https://github.com/opencontainers/image-spec/blob/main/layer.md) conventions for deletions. Paths are relative to DST, so `tar -x -C ./alpine -f deps.tar` applies a `#L` export to the tree mounted there, and entries come depth-first by name, so two runs that make the same changes give the same entries in the same order.

| Node | Entry |
| --- | --- |
| Copy (file) | A regular file with the copy's data, mode, and mtime |
| Copy (directory) with nothing of that name below | A directory with its own mode and mtime |
| Copy (directory) that replaced a lower name (removed, then made again) | The directory, then `<dir>/.wh..wh..opq`, so nothing below shows through |
| Whiteout | An empty file, `<parent>/.wh.<name>` |
| Directory marker | A directory, with the mode and mtime of the snapshot taken when the marker was made, so parents come before their children |
| Symbolic link | A symlink entry with the target as the guest wrote it, absolute or relative |
| FIFO | A FIFO entry |

- **Ownership:** entries carry uid and gid 0 and no names, as a rootless build's layers do. devfs shows every host file as the guest's user, so there's no other owner to keep.
- **Names:** pax records carry names longer than ustar allows.
- **Mode bits:** the permission bits. 9front's `DMAPPEND` and `DMEXCL` have no tar equivalent and are dropped, and a pax global record says so, `H9.dropped=append,excl`, when any were set.
- **Reserved names:** a file the guest named `.wh.foo` or `.wh..wh..opq` would read as a whiteout, so it's left out, with "h9: export: skipped #L/etc/.wh.foo: reserved name" on stderr and a count in the run's status.

### `--archive` reads whiteouts

`--archive` reads an OCI layer as a layer:

- **On a stack,** where its instance is a member, `.wh.<name>` hides `<name>` in the members below it, and `<dir>/.wh..wh..opq` hides everything below in `<dir>`. The members above it, and the stack's overlay, see the result. An `.h9a` has no whiteouts.
- **Off a stack,** an archive replaces what's at DST or makes a one-level union with it, and there's nothing below for a whiteout to hide, so whiteouts are dropped.
- **In the kernel,** the archive's instance keeps them as whiteout nodes, and a `union` instance asks a member that's an `#O` instance about a name before walking the members below. A whiteout ends the walk there as "does not exist", and an opaque directory ends the merge of that directory. Directory reads leave out the hidden names. A member of any other kind is walked as now.

So the layers of a run are a stack again in the next: `--archive deps.tar:#L --archive app.tar:#L` puts `app` over `deps` over what's below, with `app`'s deletions applied, as an image's layers are.

### The plan

An export is something h9 writes on the host, not a line of the namespace, so `--print` lists them on a line of their own above `namespace:`, as given, and `--ns` never sees them:

```text
limits:   write=overlay net=enable
exports:  deps.tar:#L
namespace:
  bind '#/' /
  …
  bind -r '#U/home/me/alpine' '#Olinux'                  ro
  bind -c '#O' '#Olinux'                                 eph  # exported to deps.tar
  …
```

The instance's line gets an `exported to FILE` note.

### The library and the browser host

- **`Machine.Options.exports: []const Export`,** each `.{ .dst = "#L", .writer = w }`. `run` writes each archive to its writer after the last process exits and before it returns. The CLI fills it from the flags, opening each FILE first.
- **The run's status** gives, for each export, the entries written, the names skipped, and an error if the writer failed. A failed export never replaces the guest's own status.
- **The browser host:** `createMachine({ mounts, exports: ['#L'] })`, and the run's result has `changes`, a `Uint8Array` per DST, which an `archive` mount takes back.

### Keeping instances alive until the export

The namespace builder takes an extra reference on each exported instance, and drops it after the export, so the last process's teardown doesn't free it first. A new C leaf in `devoverlay.c` walks an instance under its QLock, from a path below its top, and calls back into Zig for each node:

```c
/* Calls fn once per memory node under path, depth-first by name; returns -1 with the error set if fn fails. */
int h9_overlay_walkchanges(int id, char *path, int (*fn)(void *arg, OvEntry *e), void *arg);
```

`OvEntry` gives the node's kind (copy, whiteout, marker, link, or FIFO), its path relative to `path`, whether it's opaque, its `Dir`, a link's target, and a read function for a copy's blocks. The tar is built in Zig, in `src/changes.zig`, which also reads whiteouts for `--archive`, so the C side knows nothing about the format. A machine left `stuck` after a timeout still has processes holding its namespace, so it isn't exported, and the run's status and the CLI say so.

### The CLI's notices

- With `/` exported, [overlay](epoch-0/overlay.md)'s notice becomes "h9: changes to the root saved to root.tar (N entries)", on a terminal only, as before.
- Without it, the notice suggests the export: "h9: changes to the root under /lib, /sys were discarded (--export-changes FILE saves them)".
- If an archive can't be written, h9 prints "h9: export: FILE: <error>" and exits 125 when the guest succeeded, and keeps the guest's status when it didn't.

## Rationale

**One archive per destination, not one for the run.** The first draft of this proposal wrote every overlay into one archive keyed by guest path, with the cwd's changes under `mnt/term/cwd/` and a filter to apply only the root's. [mounts](mounts.md) gave every tree a destination, and the destination is the name a layer needs: an export of `#L` applies to the tree mounted on `#L`, and mounts there again, with no prefix to strip. It also removes `--export-tmp`: `/tmp` is exported when it's named, and never otherwise.

**A path under an overlay.** Exporting `#L/etc` or `/usr/glenda/lib` costs a prefix check in the walk, and covers the cases a single archive needed a `tar --exclude` for.

**`--archive` as the way back.** The first draft rejected `--import-changes`, since runs that depend on each other's leftovers are what [overlay](epoch-0/overlay.md) set out to stop. A layer named on the command line isn't a leftover: the user chose it, and the plan shows it. `--archive` already puts a tree on a stack, so teaching it whiteouts is all an import needs, and every OCI layer, h9's or Docker's, mounts the same way.

**Whiteouts in the union, not by flattening.** `--archive` could apply a layer's deletions by unpacking the members below it into memory, but that copies the whole stack. Asking a member about a whiteout costs a lookup in a tree that's already in memory, and it's what overlayfs does with several lower layers.

**An eph overlay over the stack, not an `rw` member.** A build that writes a host directory through an `rw` member gets the union's rules: no overlay, `EXDEV` for renames across directories, and changes that can't be told from what was there. An overlay records exactly what the step did, moves renamed files in memory, and leaves the host trees as they were, so a failed step leaves nothing behind.

**A flag naming DST, not a mount option.** `export=FILE` on a mount reads well for `--dir ./src:/src:eph,export=src.tar`, but a stack's overlay belongs to no one mount, and `/tmp`'s and the cwd's come from `--write`, with no mount flag to put it on. A flag that names DST reaches all of them, and parses the same way.

**`--export-changes`, not `--export`.** In Plan 9, exporting is what `exportfs` does, serving a namespace, and h9 serves with `--serve`. The longer name says what's written.

**Tar, and OCI's layer format.** Tar has a reader on every host, Windows' `tar.exe` included. Plain tar can't represent a deletion, and OCI's whiteouts and opaque markers are the common way to: Docker, Podman, `umoci`, and `crane` read them, and they map one to one onto `#O`'s nodes.

**Rejected: a directory tree, a diff, or the changes visible to the guest.** A directory can't hold a deletion without the same `.wh.` files, and fails halfway in more ways. A diff can't carry binaries, modes, links, or empty directories. A `changes` file in `#O` would let the guest run its own tar, but 9P has no way to say whiteout, and the run's changes would become something the guest can read during the run.

**No `-` for stdout.** The guest owns stdout, and anything it wrote there would corrupt the archive without an error. A `/dev/fd/N` path or a pipe streams it just as well.

**Export when the guest fails or is killed.** A failed step is exactly when you want to see what it did. Its status is reported unchanged.

**Exit 125 only when the guest succeeded.** A run that couldn't write its archive lost what it was asked for, so a script shouldn't see 0, but a failed guest's status is the more important failure to keep.

**Skipping reserved names.** OCI has no escape for a literal `.wh.` file, and writing one would say the guest deleted something it didn't.

**A reference, not a new rule for freeing.** "The last close frees the instance" stays. An export adds one holder, only when asked.

## Compatibility

- **CLI:** `--export-changes FILE[:DST]`, repeatable. Exit codes are unchanged, except that 125 can also mean a failed export. The first draft's `--export-tmp` is dropped.
- **`--archive`:** an archive with `.wh.` entries now deletes names on a stack instead of making files with those names. An OCI layer means that already, and no tree h9 makes has such names.
- **`--print` and `--ns`:** an `exports:` line, which `--ns` never reads, and a note on an exported instance's line. Saved plans replay as before.
- **`Machine.Options`:** `exports`, empty by default, and the run status's export counts and errors.
- **Browser host:** `createMachine`'s `exports`, and `changes` on a run's result.
- **Sandbox defaults:** unchanged. Nothing is exported unless asked.
- **Root tree and `third_party/`:** unchanged.

## Security

- **The guest gains no new reach.** It can't name, open, or see FILE, which h9 opens before the run and writes after the guest's processes have exited.
- **The guest decides the archive's contents,** which is the point. Extract it as any untrusted layer. Names are guest names, which can't hold `/`, `.`, or `..`, and the exporter checks anyway. Reserved names are skipped, so an archive can't carry a deletion the guest didn't make through `#O`.
- **Reads aren't widened.** The exporter reads only memory nodes, never a lower tree, so a file hidden by the access rules can't reach the archive, and a marker's `Dir` is the snapshot the guest was already allowed to stat.
- **Whiteouts in `--archive`** hide names in the members below on the same stack only, which a guest could do in its own overlay anyway. They never reach a host tree.
- **Size is bounded.** Everything exported is in memory, counted against `--memory`.
- **Between machines,** each machine exports only its own instances. The walk leaf checks the instance's pool, as an attach does.

## Done criteria

Demo: three runs build an Alpine app in layers, with the host tree unchanged:

```sh
h9 --dir ./alpine:#L --export-changes deps.tar:#L sh -c 'apk add python3 && rm /etc/motd'
h9 --dir ./alpine:#L --archive deps.tar:#L --export-changes app.tar:#L sh -c 'mkdir -p /app/tmp && echo hi > /app/tmp/x && mv /app/tmp/x /app/x'
h9 --dir ./alpine:#L --archive deps.tar:#L --archive app.tar:#L sh -c 'python3 -V; cat /app/x; test ! -e /etc/motd'
tar -tvf deps.tar | grep -e usr/bin/python3 -e etc/.wh.motd
```

Integration cases:

- [ ] `test "a new root file is exported relative to / [overlay-export]"`
- [ ] `test "a #L export is relative to the Linux tree and mounts again with --archive [overlay-export]"`
- [ ] `test "a removed file is exported as a .wh. whiteout [overlay-export]"`
- [ ] `test "a directory removed and made again is exported as opaque [overlay-export]"`
- [ ] `test "links and FIFOs are exported as tar links and FIFOs [overlay-export]"`
- [ ] `test "a path under an overlay exports only that subtree [overlay-export]"`
- [ ] `test "the cwd under --write=ephemeral exports relative to the cwd [overlay-export]"`
- [ ] `test "/ doesn't include /tmp, and /tmp exports when named [overlay-export]"`
- [ ] `test "a DST with no overlay is a usage error naming why [overlay-export]"`
- [ ] `test "two exports of one DST, or nested ones, are a usage error [overlay-export]"`
- [ ] `test "an unwritable FILE is a usage error and nothing runs [overlay-export]"`
- [ ] `test "a FILE ending in .gz is gzipped [overlay-export]"`
- [ ] `test "a run with no changes writes an empty archive [overlay-export]"`
- [ ] `test "changes are exported when the guest fails or times out [overlay-export]"`
- [ ] `test "a file named .wh.x is skipped with a message [overlay-export]"`
- [ ] `test "two identical runs give the same entries in the same order [overlay-export]"`
- [ ] `test "--archive on a stack hides a whited-out name in the members below [overlay-export]"`
- [ ] `test "--archive on a stack with an opaque directory hides that directory below [overlay-export]"`
- [ ] `test "--archive off a stack drops whiteouts [overlay-export]"`
- [ ] `test "--print lists exports and still replays with --ns [overlay-export]"`

Backend case: two machines in one process, each exporting `/` to its own writer, see only their own changes.

Browser host:

- [ ] `test('createMachine exports #L as bytes that mount again as an archive [overlay-export]')`

## Implementation

1. Whiteouts through unions: a `union` instance asks an `#O` member for a whiteout or an opaque directory before walking the members below, and directory reads leave hidden names out. Kernel tests beside the union ones.
2. `src/changes.zig`: the pax and OCI writer, the reserved-name check, and the whiteout reader for `--archive`, with unit tests on hand-built trees.
3. `h9_overlay_walkchanges` in `devoverlay.c`, the extra reference, and resolving each DST to an instance and a path in the plan.
4. `Machine.Options.exports`, the export in `run`, and the status fields.
5. The CLI flag, opening FILE early, gzip by suffix, exit 125, `--print`'s `exports:` line and note, and the notice.
6. The browser host's `exports` and `changes`.
7. MANUAL.md, README.md, and the docs (containers, recipes, and embedding), and SPEC.md once built.

## Open issues

- **Owners in a Linux tree.** If the overlay comes to keep a Linux program's `chown`, the archive should carry those uids and gids instead of 0.
- **Serving a layer without copying it.** `--archive` copies a layer into memory, against `--memory`. A large base layer could be served read-only from the archive's bytes, as `#Hroot` serves the built-in root, with only the overlay above it in memory.
- **Exporting between runs of one machine.** An embedder that calls `run` several times on one `Machine` gets one archive per run. Whether a long-lived machine should export on demand, without ending a run, is left for a REPL-like use to decide.

## Updates

- 2026-11-22: Rewritten for [mounts](mounts.md). Exports are per destination and relative to it, `--archive` reads OCI whiteouts so an export mounts again as a stack member, `--export-tmp` is gone, and links and FIFOs are exported.
