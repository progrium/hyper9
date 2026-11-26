---
slug: upper-layers
title: Writable layers on the host
status: implemented
created: 2026-11-22
authors: [progrium]
depends: [ephemeral-writes, mounts, linux-symlinks, linux-fifo, port-streams]
areas: [sandbox, cli, kern, api, web]
branch: [main]
---

# Proposal: Writable layers on the host

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Add `up`, a mount option that makes a writable tree the copy-on-write layer over what's below it, the way overlayfs's `upperdir` is: `--dir ./step1:#L:up` puts `step1` on top of the Linux stack, and every change the guest makes lands there as a layer. A file from below is copied into `step1` on its first write, a removed name leaves a `.wh.<name>` file, and a directory removed and made again gets `.wh..wh..opq`, so `step1` is an [OCI image layer](https://github.com/opencontainers/image-spec/blob/main/layer.md), unpacked. Every stack member reads those whiteouts, so `--dir ./step1:#L` mounts the layer again in a later run, and `tar -C step1 -cf step1.tar .` makes it an archive that `--archive` stacks the same way. Writes go to the host as the guest makes them, never to the trees below, and never to memory, so a build can go step by step as a Dockerfile does, with each step's layer kept on disk. This supersedes [overlay-export](overlay-export.md), which wrote the in-memory overlay to a tar at the end of the run.

## Background

### h9 today

- **[ephemeral-writes](ephemeral-writes.md)** added `#O` (`src/kern/devoverlay.c`). A `cow` instance is a tree in memory over a lower chan, made of copies, whiteouts, and directory markers, and since [linux-symlinks](linux-symlinks.md) and [linux-fifo](linux-fifo.md) also links and FIFOs. Renames within an instance, across directories too, are moves in that tree.
- **[mounts](mounts.md)** made `/` and `#L` stacks, `#Oroot` and `#Olinux`: `union` instances whose members are merged at every depth. Under `--write=overlay` and `ephemeral` a `cow` instance goes over the whole stack, in memory. A member marked `rw` takes the writes instead, and the stack then has no overlay: creates go to that member, writes go to whichever member holds the file, a read-only member's file can't be written, and a removed name in a lower member comes back.
- **A rename across directories** in a stack with an `rw` member is the union's, which answers `EXDEV` (`h9_overlay_move`), so package managers that stage files in one directory and rename them into another copy them instead, or fail.
- **`--archive`** reads every tar entry as a file, so an OCI layer's whiteouts come out as empty files named `.wh.<name>`.

### What people want

- **Build in layers.** A tool that builds an app from a runtime, its dependencies, and its source wants each step's output as its own layer on disk, so a step whose inputs haven't changed is skipped and its layer reused, and so the next step mounts the layers below it as they were.
- **Keep what a run did without changing the trees it ran on.** Run `apk add`, `mk install`, or an unknown script against a base, keep the result, and look at it before applying it anywhere.
- **No memory ceiling.** The in-memory overlay counts against `--memory`, so a large install needs a large machine, and its result is gone if h9 is killed.

## Proposal

### The option

`up`, long form `upper`, is a mount option for any tree the guest could write: `--dir`, `--url` to a writable 9P server, and `--tmp`. It makes the mount the writable layer over what's beneath it:

| Where | What's beneath |
| --- | --- |
| On a stack, `/` or `#L` | Every other member of the stack. The `up` member goes on top whatever its order, and at most one member of a stack can be `up`. |
| A path under a stack, such as `#L/etc` | The stack's tree under that path |
| Any other DST | What's at DST when the mount is made |

```sh
h9 --dir ./alpine:#L --dir ./deps:#L:up sh -c 'apk add python3 && rm /etc/motd'
h9 --dir ./alpine:#L --dir ./deps:#L --dir ./app:#L:up sh -c 'pip install -r /src/req.txt'
h9 --dir ./alpine:#L --dir ./deps:#L --dir ./app:#L python3 /app/main.py
```

- **Access:** an `up` mount is writable, so a `--dir`'s host path joins the access rules as `rw` does. The trees beneath are only read.
- **Conflicts:** `up` with `ro`, `rw`, or `eph`, two `up` members on one stack, or `up` on a source that can't be written (`--builtin`, `--archive`, a static tree) is a usage error (exit 2). So is `up` under `--write=none`.
- **A stack with an `up` member has no overlay in memory,** as one with an `rw` member has none now.
- **The tree can be empty or not.** A fresh directory makes a new layer, and one that's already a layer goes on growing.

### How writes land

The layer holds only what the guest changed, in the OCI layer format:

| The guest | In the layer |
| --- | --- |
| Creates a file, directory, link, or FIFO | It's made there |
| Writes, truncates, or changes the mode or times of a file only below | The file is copied into the layer first, with its parent directories, then changed there. Copying a file is the whole file, once. |
| Changes the mode or times of a directory only below | The directory is made in the layer with the new mode or times, holding nothing else |
| Removes a name that exists below | Any copy in the layer is removed, and `<parent>/.wh.<name>` is made, empty |
| Removes a name only in the layer | It's removed |
| Makes a name that's whited out | `.wh.<name>` is removed. A new directory over a whited-out one also gets `<dir>/.wh..wh..opq`, so nothing below shows through. |
| Renames, in one directory or across directories | A file from below is copied up first. Then it's the layer's own rename (the host's, a 9P2000.L server's `renameat`, or `#O`'s move), and the old name is whited out if it exists below. A directory that exists below is `EXDEV`, as in overlayfs. |

- **Reserved names:** the guest can't make a name starting with `.wh.` in an `up` layer: it's "permission denied". Such a name would read as a whiteout.
- **What it reads:** a walk tries the layer first, then the trees beneath, as a union does, except that a whiteout ends the walk as "does not exist" and an opaque directory isn't merged with what's below it. A directory read lists each name once and never lists `.wh.` files.
- **Links and FIFOs** are made in the layer as the tree it's on makes them: `#U` makes host links and FIFOs, `#O` keeps them in memory, and a 9P2000.L server makes them with `Tsymlink` and `Tmknod`. On Windows, a host link needs the privilege Windows asks for (Developer Mode or an elevated process), and a FIFO is "permission denied".
- **Owners** are the layer's tree's own: on a host directory, the user h9 runs as.

### Every stack member reads whiteouts

A layer has to mount again as it was, so a stack's `union` instance honors whiteouts in every member, not only in an `up` one:

- **A walk** that doesn't find a name in a member asks that member for `.wh.<name>` before walking the members below. If it's there, the name doesn't exist.
- **A directory** in a member that holds `.wh..wh..opq` isn't merged with the members below.
- **Directory reads** leave out whiteouts and the names they hide.
- **`--archive`** keeps an archive's whiteouts as `#O` whiteout nodes instead of files, so the same rules apply to it.

Off a stack, a `--dir` or `--archive` is bound as it is, and a `.wh.` file in it is a file. A tree with no `.wh.` files behaves exactly as now. The extra walk happens only on a miss, and only in members above the bottom one: on a host tree it's a local `lstat`, and on a 9P member a mount index ([mount-index](mount-index.md)) answers it without the server.

So `--dir ./deps:#L --dir ./app:#L` stacks `app` over `deps` with `app`'s deletions applied, and `--archive deps.tar:#L --archive app.tar:#L` does the same from archives, whoever made them.

### The plan

`up` is a `cow` instance whose upper is a tree instead of memory. In namespace syntax it's h9's `bind` with `-u`, which makes a `cow` instance over OLD with NEW as its upper, and binds it over OLD:

```text
  bind -r '#U/home/me/alpine' '#Olinux'                  ro
  bind -r -b '#U/home/me/deps' '#Olinux'                 ro
  bind -u '#U/home/me/app' '#Olinux'                     up
```

- `--print` writes `up` mounts that way, and `--ns` replays them.
- A bare `#O` attach's `clone` takes `upper PATH`, resolved in the writer's namespace, as `add` is.
- devproc prints such an instance as its `bind -u` line, so `ns` output replays.

### The library and the browser host

- **`Machine.Options.mounts`:** `Mount.access` gains `.up`, and `Mount.parse` reads `up` and `upper`.
- **The browser host** has no host directories, so a layer there is a tree the page serves: `{ port, dst: '#L', up: true }`, a `MessagePort` 9P server, holds the layer, and the page keeps it as it likes, in memory, IndexedDB, or OPFS. `up` on `--tmp` also works anywhere, as a layer in memory that's gone when the machine ends, as `eph` is.

### The CLI's notice

[overlay](overlay.md)'s notice that the root's changes were discarded suggests a layer: "h9: changes to the root under /lib, /sys were discarded (--dir DIR:/:up keeps them in DIR)".

## Rationale

**On disk, not in memory then exported.** [overlay-export](overlay-export.md) kept the run's changes in the `#O` overlay and wrote them to a tar when the run ended. That bounds a step by `--memory`, loses everything if h9 is killed, and needs an export step and a flag to say where. A layer on disk has none of those, and an archive is one `tar` away. What the export offered beyond that, a run that writes nothing on the host until it ends, is close enough here: an `up` layer is a directory the user chose, usually a fresh one, and nothing else on the host is written.

**overlayfs's model and OCI's format.** An upper directory over read-only lowers, with copy up, `.wh.` whiteouts, and opaque directories, is what overlayfs, Docker, and Podman use, and what every container tool reads. A layer h9 makes is a layer those tools can stack, and theirs stack in h9.

**`up` as a mount option, not a new flag.** The layer is a tree brought in from outside the machine, which is what a mount flag is, so `--dir`, `--url`, and `--tmp` all get it, with their own syntax, their own access rules, and `--print` lines. A separate flag would need its own DST parsing and its own way to name the source.

**On top of the stack, whatever the order.** Copy up needs the layer above everything it covers. A later member that went above it couldn't be written through it, so `up` always goes on top, and a second one is an error rather than a guess at which wins.

**Whiteouts in every member.** A layer has to mean the same thing when it's mounted again, read-only, under a new layer. Honoring whiteouts only in members marked somehow would make the user remember which directories are layers. The cost is a lookup on a miss in members above the bottom, and trees without `.wh.` files see no change in meaning.

**Refusing `.wh.` names.** OCI has no escape for a literal `.wh.` file, and a layer that held one would hide a name the guest never removed. Refusing the create is honest, and such names are rare outside layers themselves.

**`EXDEV` for a directory from below.** Moving a directory that exists below means copying its whole subtree up, which can be large. overlayfs answers `EXDEV` without `redirect_dir`, and `mv` and package managers copy instead. A file from below is copied up and renamed, so the staging renames that broke under an `rw` member work.

**No atomicity for a layer.** A layer is written as the guest goes, so a step that fails or is killed leaves a partial one. Making it atomic would mean writing to a temporary tree and swapping it in at the end, which a build tool can do with two renames on the host (`--dir ./app.tmp:#L:up`, then `mv app.tmp app` when the step succeeds) and h9 can't do as well for a 9P server.

**`bind -u`.** The plan has to replay, so `up` needs a namespace form. `-u` follows `-r` in h9's fork of `bind(1)`, and reads as overlayfs's `upperdir`.

**Rejected: exporting the in-memory overlay ([overlay-export](overlay-export.md)).** Superseded by this: it covers the same uses with one mechanism, one format, and no memory ceiling. Embedders that want a layer as bytes can put `up` on a tree they serve.

**Rejected: an `rw` member that reads whiteouts but doesn't copy up.** It would keep today's union semantics for writes, so a file from a lower member still couldn't be changed, and a removed lower name would still come back. Copy up is what makes a member a layer.

## Compatibility

- **CLI:** a new mount option, `up` (`upper`). Exit codes are unchanged.
- **Stacks:** a stack member with `.wh.` files now hides names in the members below, and an archive's `.wh.` entries are whiteouts instead of files. OCI layers already mean that, and no tree h9 makes has such names.
- **`--print`, `--ns`, and `ns`:** `bind -u` lines, and the `up` annotation. h9's `bind` in `#H/over` takes `-u`.
- **`Machine.Options`:** `Mount.access` gains `.up`.
- **Browser host:** `up` on a port mount.
- **Sandbox defaults:** unchanged. Nothing is an `up` layer unless a mount says so.
- **Other proposals:** [overlay-export](overlay-export.md) is superseded. [linux-fifo](linux-fifo.md)'s note that exported overlays carry FIFOs becomes: a layer on a host directory holds them as host FIFOs.
- **Root tree and `third_party/`:** unchanged.

## Security

- **Host writes stay inside the layer.** An `up` `--dir` joins the access rules as `rw` does, so the guest can write that directory and nothing else it couldn't before. The trees beneath are only read, and a copy up reads through the same checks as any read, so a file hidden by the access rules can't be copied into a layer.
- **Whiteouts hide, never delete.** A `.wh.` file hides a name in the members below it on one stack, in the guest's own view. A guest can already hide names from itself with `bind`, and nothing below is touched.
- **Layers are untrusted input.** A layer from elsewhere can hide any name in the members below it, as any OCI layer can. Mounting it is a choice the user makes on the command line.
- **Reserved names** can't be made, so a guest can't write a whiteout except by removing a name.
- **Memory:** nothing grows with the layer except the union's qid table and directory snapshots, which count against `--memory` as now.

## Done criteria

Demo: three runs build an Alpine app in layers, with `./alpine` unchanged, then the layers stack as archives:

```sh
h9 --dir ./alpine:#L --dir ./deps:#L:up sh -c 'apk add python3 && rm /etc/motd'
h9 --dir ./alpine:#L --dir ./deps:#L --dir ./app:#L:up sh -c 'mkdir -p /app/tmp && echo hi > /app/tmp/x && mv /app/tmp/x /app/x'
h9 --dir ./alpine:#L --dir ./deps:#L --dir ./app:#L sh -c 'python3 -V; cat /app/x; test ! -e /etc/motd'
ls -a deps/etc | grep .wh.motd
tar -C deps -cf deps.tar . && tar -C app -cf app.tar .
h9 --dir ./alpine:#L --archive deps.tar:#L --archive app.tar:#L sh -c 'cat /app/x; test ! -e /etc/motd'
```

Integration cases:

- [x] `test "a new file lands in the up layer and nowhere else [upper-layers]"`
- [x] `test "writing a file from below copies it up with its parents [upper-layers]"`
- [x] `test "removing a name from below leaves a .wh. file [upper-layers]"`
- [x] `test "a directory removed and made again is opaque [upper-layers]"`
- [x] `test "a rename across directories copies up and renames in the layer [upper-layers]"`
- [x] `test "renaming a directory from below is EXDEV [upper-layers]"`
- [x] `test "links and FIFOs are made in the layer [upper-layers]"`
- [x] `test "a .wh. name can't be made in an up layer [upper-layers]"`
- [x] `test "an up member goes on top of its stack whatever its order [upper-layers]"`
- [x] `test "up off a stack layers over what's at DST [upper-layers]"`
- [x] `test "up conflicts, two up members, and up on a read-only source are usage errors [upper-layers]"`
- [x] `test "a stack member's .wh. file hides the name in the members below [upper-layers]"`
- [x] `test "a stack member's opaque directory hides the directory below [upper-layers]"`
- [x] `test "--archive on a stack reads whiteouts, and off a stack keeps them as files [upper-layers]"`
- [x] `test "--print writes bind -u, and it replays with --ns [upper-layers]"`
- [x] `test "ns prints an up instance as bind -u [upper-layers]"`
- [x] `test "up on a 9P2000.L mount keeps the layer on the server [upper-layers]"`
- [x] `test "links are made in a 9P2000.L layer, and on a .L mount, by Tsymlink [upper-layers]"`

Browser host:

- [x] `test('createMachine takes up on a port mount, and the layer mounts again [upper-layers]')`

## Implementation

1. Whiteouts in `union` instances: the `.wh.` lookup on a miss, opaque directories, and directory reads that hide them, with kernel tests beside the union ones. `--archive` keeps whiteouts as nodes.
2. `cow` instances with a chan as their upper in `devoverlay.c`: walks and reads through it, copy up, whiteout and opaque files, the reserved-name check, and renames, with the memory upper unchanged.
3. `bind -u`, `clone`'s `upper`, devproc's lines, and h9's `bind` in `#H/over`.
4. `up` in `src/mount.zig`, the plan and its conflicts in `policy.zig`, and the namespace builder.
5. The browser host's port mounts with `up`.
6. The notice, MANUAL.md, README.md, and the docs (containers and recipes), and SPEC.md once built.

## Open issues

- **Owners in a Linux layer.** A host layer's files are owned by the user h9 runs as. If the guest's `chown` should survive, the layer would need to record owners somewhere, as rootless container tools do with an xattr.
- **Copying up a large file** costs the whole file on the first write. Host filesystems with reflinks (APFS clones, Btrfs, XFS) could make it nearly free for `--dir` layers.
- **Directory renames from below.** overlayfs's `redirect_dir` records a moved directory in an xattr; a portable form could follow if `EXDEV` turns out to matter.

## Updates

- 2026-11-23: Steps 1 to 4 and 6 are on the `upper-layers` branch, with step 5 in part. The layer is built as the top member of a `union` instance rather than as a `cow` instance's upper, as step 2 has it: the up member is a union member marked up (`Member.isup`), always first, and the union's lookups, reads, creates, removes, renames, and wstats copy up, white out, and make opaque directories through it. That reuses the whiteout handling step 1 adds for stacks, and leaves `cow` instances as they were. `bind -u NEW OLD` makes a union of OLD with NEW as its up member, and `clone`'s ctl takes `upper PATH`. `--archive` keeps whiteouts as files, which a stack then reads as whiteouts, so the archive case holds without a node kind for them. `--write=ephemeral` on a stack with an up member is a usage error, as it would throw the layer's writes away. Two limits: a symlink at the top of `#L` is refused there as it is on main, since `/` there is devlinux, and a symlink can't be made in a 9P layer yet (`EPERM`), though a FIFO can (since lifted, below). `h9-web.js` takes `up: true` on a mount; a port mount with `up` waits on [port-streams](port-streams.md), so it's now in `depends`, and the browser case stays open. The 17 integration cases and the Alpine demo pass on the native backend (amd64). Not run on HVF, KVM, or the emulator, and the web case wasn't run.
- 2026-11-23: Links in a 9P layer. The 9P2000.L client makes a link from a `Tcreate` with `DMSYMLINK` and the fid's first write, its target, by `Tsymlink`, and the kernel makes one on a .L mount that way (`h9_fs_mntsymlink`), for the layer's copy up and new links, and for a Linux `symlink` on any .L mount, which was `EPERM` before. A mount under a mount index counts as .L when `#ι`'s server is `#ℓ`'s. A 9P2000 mount still refuses links. The new case passes on the native backend (amd64).
- 2026-11-23: A union directory named while the layer didn't have it, such as a process's working directory in `/app` while `/app` was only below, kept only the members below, so names relative to it missed what had changed in the layer since: a file written there read as the old one, a removed one still listed, and `O_EXCL` creates over a removed one failed with "file exists". The instance now counts the directories made in its up member, and a union chan whose members were found before the last one looks for its directory in the layer again before a walk, a read, or a create (`unfresh` in `devoverlay.c`). Found by [h9build](https://github.com/progrium/scratch/tree/main/h9build), whose build steps run in `/app`.
- 2026-11-25: Done. With [port-streams](port-streams.md) on main, a port mount takes `up` as any `--url` does, and the browser case passes: the page serves a writable 9P2000 tree in memory (`tests/web/memtree.js`) on a port, one machine writes through it as the up member of `/` over an archive, the tree holds only the changed files and the `.wh.` file, and a second machine mounts the same tree on `/` without `up` and sees the same files. The spec now describes up layers and whiteouts (`spec/sandbox.md`, `spec/kernel.md`, `spec/cli.md`, and `spec/host-js.md`), and the `[port-streams, upper-layers]` integration case no longer needs `-Dpending`. Running the cases without `-Dpending` showed "links are made in a 9P2000.L layer" failing about a third of the time: `mv` of a link from below copied it up and then didn't find it, since the mount index's reader kproc sometimes wrote the process's walk to `#ℓ` as its own, so the walk followed the link instead of stopping at it. A write to `#ι`'s data now writes its own requests (`src/kern/devhidx.c`).
