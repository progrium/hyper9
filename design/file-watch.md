---
issue: 316
slug: file-watch
title: Watching files for changes, on the host and in the guest
status: proposed
created: 2026-11-24
authors: [progrium]
depends: []
areas: [kern, linux, ninep, cli, api, sandbox, web]
branch: []
---

# Proposal: Watching files for changes, on the host and in the guest

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 has no way for a guest to learn that a file changed, so every watcher in it polls. The Linux ABI lists `inotify_init`, `inotify_init1`, `inotify_add_watch`, and `inotify_rm_watch` in its syscall table and implements none of them, so .NET, Node's `fs.watch`, dev servers, and editors either poll or fail to start. This proposal adds one change journal to the kernel, fed by three sources: the changes the machine's own processes make, on any device; changes made on the host to a `--dir` tree, found through the host's own API (inotify on Linux, FSEvents on macOS, `ReadDirectoryChangesW` on Windows) or, where that isn't available or isn't trusted, by polling; and changes on a 9P server that offers [dotfs](https://github.com/progrium/dotfs/blob/main/docs/9p-dotfs.md)'s `.fs/events`. Union and overlay instances pass their members' changes up through their own rules, so a change below an up layer or an in-memory overlay is reported only if the guest can see it. Plan 9 programs read the journal as dotfs event records from a new device, `#ν`, and a machine that serves its namespace serves it as `.fs/events`, so another h9 or a dotfs client can follow it. Linux programs get inotify on the same journal. The work lands in three phases, each useful alone: the journal with the guest's own changes, `#ν`, and inotify; then the host and server sources, with unions passing changes up; then serving.

## Background

### What exists today

- **Nothing reports a change.** No device in `src/kern/` or `third_party/drawterm/kern/` tells anyone that a file changed. A Plan 9 program that wants to know stats in a loop. 9front has no change notification either: Plan 9 programs that react to files poll, or are told through the plumber or a file server's own protocol.
- **inotify is a name in a table.** `src/linux/nr.zig` names the four inotify calls on both architectures, and the Linux ABI answers them `ENOSYS`. [h9x](https://github.com/progrium/h9x) sets `DOTNET_USE_POLLING_FILE_WATCHER=1` for .NET plans because ASP.NET fails to start without inotify. Node's `fs.watch` throws, and libraries built on it (chokidar, webpack, Vite, nodemon, and `tsc --watch`) fall back to stat polling where they have a fallback. Go's fsnotify, Python's watchdog, and Rust's notify do the same or fail.
- **h9 already reads dotfs events.** [mount-index](epoch-0/mount-index.md)'s `#ι` layer opens a 9P server's `.fs/events` with `coalesce` and uses its records to demote stale index entries ([spec/ninep.md](../spec/ninep.md#metadata-indexes)). The records are used only inside the layer and are never shown to the guest.
- **Readiness has a mechanism; change doesn't.** `h9_poll` and `#ε`'s eventfd, epoll, and signalfd instances ([spec/abi-linux.md](../spec/abi-linux.md)) let a Linux process wait on a kernel object. [file-interface](file-interface.md) Part 1 proposes a `watch(chan, events, waker)` device operation, but it's readiness (whether a read would block), not a file's contents or names changing.
- **Trees come from many places.** A machine's files are host trees through `#U`, `#O` instances (in-memory overlays, `--tmp`, `--archive`, and the `#Oroot` and `#Olinux` stacks, including [upper-layers](epoch-0/upper-layers.md)' up members), 9P servers through devmnt behind `#ℓ` and `#ι`, static dotfs trees, and the built-in root ([mounts](epoch-0/mounts.md)). On the browser host, trees are archives, WebSocket servers, and pages' own servers over a `MessagePort` ([port-streams](epoch-0/port-streams.md)).

### What people want

- **Dev loops.** A dev server, test runner, or compiler in watch mode, running in h9, that rebuilds when the user saves a file in their editor on the host.
- **Programs that need inotify to start.** ASP.NET's configuration reload, and tools that call `inotify_init` unconditionally.
- **Watching a machine from outside.** A host tool, a page, or another machine that follows what a build or an agent is changing, as it happens, without walking the tree.
- **Watching inside a machine.** One guest process reacting to another's writes, in any tree, including ones that exist only in memory.

## Proposal

### Phases

The proposal is one design, built in three phases. Each phase ships on its own, with its own Done criteria, and leaves nothing half made for the next.

| Phase | Adds | Useful for |
| --- | --- | --- |
| 1: the journal | The journal, Source 1 (the guest's own changes), `#ν` and `fsevents`, Linux inotify, and `--watch guest` and `none` | Programs that need inotify to start, such as ASP.NET, and one guest process watching another's writes, in any tree |
| 2: outside changes | Source 2 (host trees, on each host's backend or polling), Source 3 (9P servers' `.fs/events`), unions passing up their members' changes, `--watch auto` and `poll`, `--watch-interval`, and `watch=` | Dev loops: a guest watcher seeing an edit made on the host |
| 3: serving | `.fs/events` under `--serve` | Watching a machine from outside it |

Until Phase 2, `--watch auto` means `guest`. Phase 3 doesn't need [kernel-serve](epoch-0/kernel-serve.md): with exportfs, `.fs` is a bind on the served root, and kernel-serve later hides it from listings.

### The journal

Each machine has one change journal in the kernel (`src/kern/watch.c`, with the host side in Zig). A change is a record with a sequence number, an operation, the directory it happened in, and the name in that directory:

| Operation | Meaning |
| --- | --- |
| `create` | A name was made: a file, directory, link, or FIFO |
| `write` | A file's contents changed |
| `close` | A file that was written was closed (guest changes, and hosts that report it) |
| `attr` | A mode, owner, or time changed |
| `remove` | A name was removed |
| `move` | A name moved, with its old and new directory and name |
| `access`, `open` | A file was read or opened (guest changes only, for inotify) |
| `rescan` | A directory's contents changed in ways the source couldn't name |

A directory is named by its identity, not by a path: its device, its device instance, and its qid.path. So a record doesn't depend on any process's namespace, and a bind or a rename doesn't change what a subscription is watching. The journal's sequence numbers start at the wall-clock time in microseconds when the machine starts and go up by one per record, so a number from an earlier run is never mistaken for one in this run.

Nothing is recorded unless someone subscribes. A subscription names a directory, a depth (the directory alone, or its whole subtree), and the operations it wants. Subscribing to a subtree walks it once to learn its directories' identities, as any recursive watcher on Linux does, and follows new directories as `create` records name them. Each subscription has a bounded queue; one that falls behind gets an overflow mark and loses the records after it, as an inotify queue does.

### Source 1: the guest's own changes

Every create, remove, `wstat`, rename, and write a guest process makes is recorded where the kernel makes it, with the directory's identity in hand. This works on every device that has stable qids, with no help from the device, so it covers `#U`, every `#O` instance, devmnt, `#L`, `#H`, and mounts a guest makes itself. Synthetic devices (`/dev`, `/proc`, `/net`, `/srv`, and `/env`) aren't journaled: their files change without anyone writing them, and no watcher in the cases below uses them.

Writes are recorded once per write call, and coalesced into the previous record when nothing else came between them, as Linux does. A `close` follows the last write on a fid. The records carry the pid of the process that made the change.

Before [kernel-port](kernel-port.md), the hooks are one-line calls in the vendored `chan.c` and `sysfile.c`, marked as the sandbox hooks are. After it, they're part of the port.

### Source 2: the host

A `--dir` tree's host directory is watched for changes made by anything outside the machine: the user's editor, a host build, or [host-cmd](host-cmd.md)'s commands. Every host backend gives hints, not facts. A hint is "this path may have changed", or "something under this directory changed". The watcher stats what a hint names, compares it with the last state it saw, and records the difference: a `create`, a `write`, an `attr`, or a `remove`. A `rescan` hint diffs the directory, or its subtree, against what was last seen. So every backend reports the same operations, and a backend that drops or merges events (they all can) is caught up by a scan rather than a reset.

| Host | Backend | Notes |
| --- | --- | --- |
| Linux | inotify | A watch per directory, added for the subtrees someone subscribes to. `IN_MOVED_FROM` and `IN_MOVED_TO` with one cookie become a `move`. `IN_Q_OVERFLOW` is a `rescan` of each watched tree. The native backend shares h9's process, so it's the same. |
| macOS | FSEvents | One stream per tree, recursive, with `kFSEventStreamCreateFlagFileEvents` for names, `NoDefer`, a 10 ms latency, and `IgnoreSelf`, delivered on a dispatch queue. `MustScanSubDirs`, `UserDropped`, and `KernelDropped` are `rescan`. Renames are paired by inode where FSEvents reports one, and otherwise are a `remove` and a `create`. |
| Windows | `ReadDirectoryChangesExW` | One recursive watch per tree, with `FILE_NOTIFY_EXTENDED_INFORMATION` for file ids, on overlapped I/O. `FILE_ACTION_RENAMED_OLD_NAME` and `NEW_NAME` become a `move`. A full buffer (`ERROR_NOTIFY_ENUM_DIR`) is a `rescan`. |
| Any | Polling | A stat of each watched directory and its entries every `--watch-interval`, backing off to four times that while nothing changes, and back once something does. |

- **Fallback.** A tree uses its host's backend unless the backend can't watch it, or runs out (inotify's `max_user_watches`, a network share `ReadDirectoryChangesW` refuses), and then polls, with a note under `-v`. A mount option forces one: `watch=poll` for a tree on NFS, SMB, or a FUSE mount, whose remote changes a host's native API doesn't see, or `watch=none` for a tree that's never watched from the host.
- **Only what's subscribed.** No host watch is made until a guest subscription reaches a `--dir` tree, and it's dropped when the last one closes. Linux's per-directory watches are made for the subscribed subtrees only. FSEvents and Windows watch the whole tree, which costs one stream or handle.
- **Echoes.** A change the guest made to a host tree is in the journal already, from Source 1, and must not come back from the host. On macOS `IgnoreSelf` drops h9's own changes. On Linux and Windows, Source 1 leaves each change's resulting stat (inode, size, and mtime) in a table for two seconds, and a host change whose stat matches is dropped.
- **Deny rules.** A host change at a path under `--read-deny`, or outside the tree's access rules, is dropped before it's recorded, as a walk to it would fail.
- **The browser host** has no host directories, so it has no Source 2. On the web host under Node, WASI preopens are polled.

When [host-handles](host-handles.md) lands, the host watcher watches beneath each directory handle: inotify through an `O_PATH` descriptor's `/proc/self/fd` name, FSEvents on the handle's resolved path with events outside it dropped, and `ReadDirectoryChangesExW` on the handle itself.

### Source 3: 9P servers

A 9P mount whose server has `.fs/events` is followed through it. `#ι` already opens the stream for the index. When something subscribes to a directory on that mount, the layer gives its records to the journal too: a `put` becomes a `create` or a `write` or an `attr` (by comparing with the entry it had), a `del` a `remove`, a `mv` a `move`, a `flags` an `attr`, and a `reset` a `rescan` of the mount. A record's path is mapped to its directory's qid through the index, or with a walk. Records the machine's own requests caused are dropped by version, as dotfs's sync profile does.

With `--index none`, `#ι` is still put in front of a mount when watching is on, as a pass-through that follows events and keeps no index. A server without `.fs/events`, a static tree, and the built-in root have no Source 3: a static tree can't change, and the others report only the guest's own changes.

### Unions and overlays

A subscription on an `#O` union directory, such as `/` or a directory in `#L`, is made on the union and on the matching directory in each member. A member's change is passed up as the union's own only if the guest would see it through the union:

- a change to a name that a member above has is hidden, and so is one under a whiteout or an opaque directory;
- a `.wh.<name>` file made in a member is a `remove` of `name`, and one removed is a `create`, if a member below has the name;
- a change in a member below to a file that's been copied up into an up layer, or into a `cow` overlay's memory, is hidden, since the guest no longer reads that copy.

So a host edit to a file in a lower `--dir` shows through a stack the way the file itself does. This is the part that costs most for least, so it's on with Sources 2 and 3 and off under `--watch guest`.

### The Plan 9 interface

`#ν` is a new device with one file, `fsevents`, bound on `/dev` after `#c`, so it's `/dev/fsevents`. Each open is a stream in dotfs's event format ([dotfs](https://github.com/progrium/dotfs/blob/main/docs/9p-dotfs.md), Extension 2: events), whose scope is a directory in the opener's namespace:

| Write before the first read | Effect |
| --- | --- |
| `scope <path>` | Watch under this directory, resolved in the writer's namespace. The default is the opener's current directory at open. |
| `since <N>` | Start with the first record after N, if the journal still has it |
| `path <dir>` | Only report changes at or below `<dir>`, relative to the scope (repeatable) |
| `coalesce` | Merge records to one path into the latest, as dotfs defines |
| `depth 1` | Only the scope directory and its entries, not their subtrees |

`scope` and `depth` are h9's. The rest, and the records, are dotfs's, so a program written for a dotfs server reads `/dev/fsevents` unchanged:

```
1795200000000412 put /src/main.go f 0644 2841 1795200004 1795200000000412 - - src=host
1795200000000413 del /src/old.go src=guest pid=42
1795200000000414 mv /tmp/x /src/x src=guest pid=42
```

- A `put`'s index line is stated when the record is read, so with `coalesce` it's the path's latest state. Its version is the record's sequence number, and its hash is `-`.
- `src=guest` records carry `pid=`. `src=host` and `src=server` mark the other sources.
- An overflow, a `since` the journal no longer has, or a `rescan` that reaches the scope ends the stream with `<seq> reset`, as dotfs defines, and the reader rescans.
- Opening needs read permission on the scope directory. The walk to the scope, and the walk of its subtree to learn its directories, cross binds and mounts as a walk from the opener does. Mounts made under the scope after it's opened aren't followed.

`#H/bin/fsevents [-c] [-1] [-s SEQ] [-p PATH]... [DIR]` writes the setup lines and prints the records, so an rc script can loop on it:

```rc
fsevents -c /src | while(r=`{read}) mk
```

### Serving

A machine that serves its namespace (`--serve`) serves `.fs/events` at the served root, scoped to it, with `#ν`'s stream behind it. So `h9 --url ws://host:port/ ...` on another machine follows the served machine's changes in its index, and a dotfs client watches it with no h9 code. `.fs/` holds only `events`: no `index`, `ctl`, or `stage`, so dotfs clients treat the server as the watchable profile without path operations. With exportfs serving, `.fs` is a bind on the served root; [kernel-serve](epoch-0/kernel-serve.md), once built, answers the walk itself, so `.fs` isn't listed, as dotfs asks.

### Linux inotify

The four inotify calls are implemented on the journal, in the Linux ABI, with the instance in `#ε` beside eventfd and epoll.

- **`inotify_init1`** takes `IN_NONBLOCK` and `IN_CLOEXEC`. The fd is readable through `poll`, `select`, and `epoll`, as an eventfd is, and answers `FIONREAD`.
- **`inotify_add_watch`** resolves the path as the Linux ABI does, following a final symlink unless `IN_DONT_FOLLOW`, and failing with `ENOTDIR` under `IN_ONLYDIR`. It makes a depth-1 subscription on a directory, or one on a file's directory filtered to its name. The same file again gives the same watch descriptor, with `IN_MASK_ADD` and `IN_MASK_CREATE` as Linux defines them. Identity is the qid, so two paths to one file are one watch.
- **`inotify_rm_watch`** ends the subscription and queues `IN_IGNORED`.
- **Reads** return whole `struct inotify_event`s, and `EINVAL` for a buffer too small for the next one. Identical consecutive events are merged, as Linux does.

| Journal | inotify |
| --- | --- |
| `create` | `IN_CREATE` |
| `write` | `IN_MODIFY` |
| `close` | `IN_CLOSE_WRITE` |
| `attr` | `IN_ATTRIB` |
| `remove` | `IN_DELETE`; on the watched file or directory itself, `IN_DELETE_SELF` then `IN_IGNORED` |
| `move` | `IN_MOVED_FROM` and `IN_MOVED_TO` with one cookie, or one of them when only one side is watched; on the watched one itself, `IN_MOVE_SELF` |
| `open`, `access` | `IN_OPEN`, `IN_ACCESS`, and `IN_CLOSE_NOWRITE`, for the guest's own opens and reads |
| An unmount of the watched tree | `IN_UNMOUNT` then `IN_IGNORED` |
| Overflow, or a `rescan` | `IN_Q_OVERFLOW` |

`IN_ISDIR` is set for directories. `/proc/sys/fs/inotify/max_user_watches`, `max_user_instances`, and `max_queued_events` read the machine's limits, which are 65536, 128, and 16384 by default, as programs such as VS Code's server and .NET read them. `fanotify_init` stays `ENOSYS`, as it's `EPERM` for an unprivileged process on Linux anyway.

### The CLI and the library

| Flag | Meaning |
| --- | --- |
| `--watch auto` | The default. All three sources, each host tree on its host's backend, falling back to polling |
| `--watch poll` | The same, with every host tree polled |
| `--watch guest` | Only the guest's own changes, Source 1, without unions passing up members' changes |
| `--watch none` | No journal: `#ν` isn't bound, the inotify calls are `ENOSYS` as now, and `.fs/events` isn't served |
| `--watch-interval DUR` | The polling interval, 1 s by default |
| `watch=native\|poll\|none` | A mount option on `--dir` (all three) and `--url` (`none`) |

`--print` adds a `watch:` line with the mode and interval, and `watch=` on each mount that has it. `Machine.Options` gains `watch: Watch`, with the mode, the interval, and the inotify limits, and `Mount` gains `watch`. The browser host's `createMachine` takes `watch` the same way.

## Rationale

**One journal, three sources, several views.** A watcher wants one answer, whatever tree the file is in. The guest's own changes are exact and cost nothing to find; the host's and a server's are the ones that need a mechanism. Putting them in one place, with dotfs records and inotify events as two views of it, means inotify works on an in-memory overlay as well as a host tree, and a Plan 9 program and a Linux one see the same changes. It's the same shape as [file-interface](file-interface.md): one interface inside, several protocols at the edge.

**Identity, not paths.** A Plan 9 namespace is per process, so no one path names a file for everyone. A directory's device, instance, and qid are the same in every namespace, which is also how inotify identifies a watch: by inode, not by name. Paths are put back in at the edge, from the subscription's walk.

**Hints, then a stat.** FSEvents merges events and doesn't say what happened, inotify drops events on overflow, `ReadDirectoryChangesW` drops a full buffer, and polling has only stats. Treating every backend's output as a hint and deciding from a stat makes them report the same thing, and makes a dropped event a scan instead of a reset the reader has to handle. Every cross-platform watcher (Watchman, notify, and libuv) ends up doing this somewhere.

**Lazy watches.** A machine with a large `--dir`, such as a checkout with `node_modules`, shouldn't pay for watching it unless something watches. Linux's per-directory watches are the expensive case, and they're made only for subscribed subtrees.

**dotfs's format for Plan 9.** h9 already reads dotfs's index and events, and a format that's text, line-based, and readable with `cat` fits Plan 9. Serving it as `.fs/events` means h9 needs no client of its own to watch another machine: mount-index already is one.

**A device, not a `.fs` in every directory.** Answering a walk to `.fs/events` in any directory would need every device to know about it. A device bound on `/dev` is how Plan 9 adds a kernel service, and `scope` gives what a per-directory file would.

**Rejected: fanotify on Linux hosts.** Its filesystem and mount marks would watch a whole tree with one mark, but they need `CAP_SYS_ADMIN`, which h9 doesn't have and shouldn't ask for. Its unprivileged inode marks are no better than inotify's.

**Rejected: kqueue on macOS.** `EVFILT_VNODE` needs an open descriptor per file watched and gives no names, so watching a tree costs a descriptor per file. FSEvents is recursive with one stream.

**Phases, not three proposals.** The parts land at different speeds: Phase 1 is kernel and Linux ABI code that runs anywhere, Phase 2 is a watcher per host OS with testing on each, and Phase 3 is small. But the journal's shape (identity, not paths; hints, then a stat; three sources, two views) only makes sense with all of them in view, so it's one design with Done criteria per phase.

**Not waiting for [kernel-port](kernel-port.md).** The port is a draft behind [baseline-1](baseline-1.md), [namespace-kernel](epoch-0/namespace-kernel.md), and [kernel-serve](epoch-0/kernel-serve.md), and nothing here needs it. The journal, `#ν`, and `#ε`'s inotify are h9's own C and Zig, which the port adapts as it does the other devices h9 wrote. The host watcher is Zig outside the kernel. What touches vendored code is Source 1's hooks, a few marked lines in `chan.c` and `sysfile.c`, both files the port replaces, so the hooks become calls in the ported code. The journal's interface (a directory identity, an operation, and a name) is what the port's device table would carry anyway.

**Rejected: polling only.** It's the fallback, and it works everywhere, but a second's delay and a stat of every watched directory every interval is what watchers in the guest do now, and the reason they're slow.

**Rejected: inotify without the rest.** A Linux-only inotify that watched host trees and nothing else would miss in-memory overlays, up layers, and 9P mounts, and would leave Plan 9 programs with nothing.

**Rejected: a `rescan` ending every stream.** dotfs's `reset` is right for a reader that's fallen behind. A host source that dropped events can catch up by diffing, so readers see the differences instead of starting over.

## Compatibility

- **CLI:** new flags, `--watch` and `--watch-interval`, and the `watch=` mount option. Exit codes are unchanged; a bad value is exit 2.
- **`Machine.Options`:** `watch` is new, with defaults, and `Mount` gains `watch`.
- **Linux programs:** the inotify calls succeed where they were `ENOSYS`, so a program that polled because of that now watches. `--watch none` keeps today's behaviour.
- **Plan 9 programs:** `/dev/fsevents` is new. Nothing else changes.
- **Serving:** a served root has `.fs/events`, and with exportfs a `.fs` name at its top. `mkindex` already leaves `.fs` out.
- **Mount indexes:** with `--index none`, `#ι` is still inserted as a pass-through when watching is on and a subscription reaches the mount.
- **Sandbox defaults and profiles:** unchanged.
- **`third_party/`:** marked one-line hooks in `chan.c` and `sysfile.c` until [kernel-port](kernel-port.md).

## Security

- **Nothing new is reachable.** A subscription reports only names under a directory the subscriber could already walk and read, and a host change is dropped where a walk to it would fail (`--read-deny`, or outside a tree's access rules). Polling could already learn all of it; this makes it faster.
- **Pids.** `src=guest` records name the process that made the change. Every process in a machine can already list every process in `/proc`.
- **Serving** exposes, to a client, the names of changes under the served root, including names of files that were removed. A client could learn the names by walking. The served stream is scoped to the served root.
- **Host resources.** The watcher's threads, inotify watches, FSEvents streams, Windows handles, and polling scans are bounded per machine: inotify watches by `max_user_watches` and the host's own limit, streams and handles by the number of `--dir` trees, inotify instances and `#ν` streams by `max_user_instances`, and each queue by `max_queued_events`. The journal's memory counts against `--memory`.
- **Host paths.** Host paths never reach the guest. Records name paths in the guest's namespace, relative to the subscription.

## Done criteria

Demos:

```sh
# A host edit reaches a Linux watcher
h9 --dir ./proj:#L/proj --dir ./alpine:#L sh -c 'inotifywait -m -e modify,create /proj' &
echo hi > proj/x

# A Plan 9 watcher sees the guest's own changes in memory
h9 --tmp /n/t rc -c 'fsevents -c /n/t & sleep 1; touch /n/t/a; rm /n/t/a'
```

Phase 1:

- [ ] `test "a guest create, write, and remove are recorded on #U, #O, and a 9P mount [file-watch]"`
- [ ] `test "/dev/fsevents takes scope, since, path, coalesce, and depth [file-watch]"`
- [ ] `test "fsevents prints dotfs records [file-watch]"`
- [ ] `test "inotify reports create, modify, close_write, attrib, delete, and moves with a cookie [file-watch]"`
- [ ] `test "inotify self events, IN_IGNORED, and IN_Q_OVERFLOW [file-watch]"`
- [ ] `test "inotify fds work with poll, epoll, and FIONREAD [file-watch]"`
- [ ] `test "Node's fs.watch and .NET's FileSystemWatcher see a guest edit [file-watch]"`
- [ ] `test "--watch none keeps inotify ENOSYS and no /dev/fsevents [file-watch]"`
- [ ] h9x's `dotnet-api` example (ASP.NET 8) builds and serves without `DOTNET_USE_POLLING_FILE_WATCHER`.
- [ ] [spec/kernel.md](../spec/kernel.md) and [spec/abi-linux.md](../spec/abi-linux.md) describe the journal, `#ν`, and inotify, and MANUAL.md has a section on watching.

Phase 2:

- [ ] `test "a host edit to a --dir tree is recorded, on the host's backend [file-watch]"`
- [ ] `test "a host edit is recorded with --watch poll and watch=poll [file-watch]"`
- [ ] `test "a guest write to a host tree is recorded once, not echoed by the host [file-watch]"`
- [ ] `test "a host rename is a move [file-watch]"`
- [ ] `test "an overflowed host backend rescans instead of resetting [file-watch]"`
- [ ] `test "a host change under --read-deny isn't recorded [file-watch]"`
- [ ] `test "a change below an up layer shows through, and one to a copied-up file doesn't [file-watch]"`
- [ ] `test "a whiteout is a remove through a stack [file-watch]"`
- [ ] `test "a 9P server's .fs/events reaches a guest watcher [file-watch]"`
- [ ] `test "Node's fs.watch and .NET's FileSystemWatcher see a host edit [file-watch]"`
- [ ] The host cases pass on macOS (FSEvents), Linux (inotify, and the native backend), and Windows (`ReadDirectoryChangesExW`).
- [ ] `test('a guest watcher sees changes on a port mount whose server has .fs/events [file-watch]')`, on the browser host.
- [ ] [spec/ninep.md](../spec/ninep.md) and [spec/cli.md](../spec/cli.md) describe the sources and the flags.

Phase 3:

- [ ] `test "--serve serves .fs/events, and another h9 follows it [file-watch]"`
- [ ] [spec/ninep.md](../spec/ninep.md)'s Serving describes `.fs/events`.

## Implementation

Phase 1:

1. The journal and Source 1, with subscriptions by directory identity, and kernel tests on `#O` and `#U`.
2. `#ν` and `fsevents`, so the rest can be tested from rc.
3. Linux inotify on the journal, in `#ε`, with the `/proc/sys/fs/inotify` files.
4. `--watch guest` and `none`, `Machine.Options.watch`, `--print`, h9x without `DOTNET_USE_POLLING_FILE_WATCHER`, and the docs.

Phase 2:

5. Source 2: polling first, as the fallback every host has, then inotify, FSEvents, and `ReadDirectoryChangesExW`, with the echo table and deny rules.
6. Source 3, through `#ι`, and its pass-through under `--index none`.
7. Unions passing up their members' changes.
8. `--watch auto` and `poll`, `--watch-interval`, `watch=`, the browser host, and the docs.

Phase 3:

9. `.fs/events` under `--serve`, and the docs.

## Open issues

- **`close` for host changes.** inotify on a Linux host reports `IN_CLOSE_WRITE`, and FSEvents, Windows, and polling don't. Tools that wait for `IN_CLOSE_WRITE` (some build watchers do) would see only `IN_MODIFY` for an edit on a macOS or Windows host. A `close` could be made up once a written file has been quiet for a moment, at the cost of being a guess.
- **Mounts under a scope after it's opened.** A subscription follows the namespace as it was walked. Following later binds would mean the mount table telling the journal about every bind.
- **`.fs/index` beside `.fs/events` when serving.** `mkindex` already writes one, and serving it would let a client bootstrap without walking, as dotfs's watchable profile allows.
- **Versions.** A `put`'s version is the journal's sequence number, which a reader can't compare with a server's own versions after a reconnect. dotfs readers that keep versions across runs should treat a new machine as a new server.
- **The device letter.** `#ν` is free, and ν is for notify. Any unused rune would do.
