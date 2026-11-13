---
slug: namespace-kernel
title: A namespace-only kernel build
status: draft
created: 2026-11-13
authors: [progrium]
depends: [browser-host, kernel-serve, port-streams, dotl, ephemeral-writes]
areas: [kern, build, web]
branch: []
---

# Proposal: A namespace-only kernel build

## Abstract

`zig build nskernel` builds h9's kernel with nothing for running programs: drawterm's channels, mount tables, devmnt, and a handful of devices, with no vmm, CPU, loaders, segments, system call tables, personalities, devproc, or console. It holds any number of namespaces, each a Pgrp, made and composed through a new device, `#N`: open `/ns/clone` to get a namespace, copied from another or empty, and write `bind`, `mount`, and `unmount` lines in newns syntax to its `ctl`. Everything is reached over 9P2000. The host attaches to a namespace by its id as the attach name, through [kernel-serve](kernel-serve.md)'s server, and hands the kernel 9P servers to mount over `MessagePort`s ([port-streams](port-streams.md)), WebSockets, or 9P2000.L through [dotl](dotl.md). On the web it's `h9ns.wasm` and `h9ns.js`, run in a Worker on the browser host's JSPI coroutines; natively it's a static library with a small C API. Its first user is [Wanix](https://github.com/tractordev/wanix), whose host module on the page asks for one namespace per task and hands it to the task's runner: for Linux and 9front executables, an h9 machine, as `createMachine({ root: port })`.

## Background

- **What Wanix's kernel does.** Wanix is an embeddable Plan 9-like environment for the browser. Its kernel today is Go compiled to wasm: its own VFS (`fs/vfs`) with binds and unions, per-task namespaces, `#` devices for the browser, and task drivers that run WASI, Go, JavaScript, and v86 in Workers. Most of it is namespace composition: defining file trees and mounting them into namespaces. The planned split keeps only that in a *namespace kernel* in a Worker, and moves orchestration (elements, the JS API, tasks, page-only trees such as the DOM and OPFS) to a *host module* on the page. The two talk 9P over MessageChannels; Wanix's duplex fs RPC becomes a client library in the host, not part of the kernel.
- **drawterm's kernel is mostly namespace already.** Its channels and walks (`chan.c`), mount tables (`pgrp.c`, and h9's `pgrpcpy` in `src/kern/proc.c`), the device switch (`dev.c`), the system call wrappers (`sysfile.c`), the 9P client (`devmnt.c`), `devroot`, `devpipe`, and the runtime under them (`qio.c`, `allocb.c`, `sleep.c`, `qlock.c`, `rwlock.c`, `waserror.c`) are about 8,000 lines, plus libc's formatting and 9P conversion. Everything h9 adds to run programs sits on top: `src/vmm/`, the a.out and ELF loaders, `segment.zig`, `syscall.zig`, `src/linux/`, devproc, devcons and the console, devlinux, and most of `machine.zig`.
- **h9 already composes namespaces without a guest.** The namespace builder calls `sysbind`, `sysmount`, and `sysopen` from Zig through `src/kern.zig`, and `--ns` replays newns-syntax files (`src/newns.zig`, run by `machine.zig`'s replay), including a bare `#O` as a fresh in-memory overlay.
- **The browser host already runs this kernel in a Worker** ([browser-host](browser-host.md)): kernel processes are coroutines on JSPI (`src/web/coro.c`, `src/kern/os-wasm.c`), no `SharedArrayBuffer` or cross-origin isolation is needed, and `hstream.zig` carries 9P over the page's WebSockets.
- **What's missing** is a server that needs no guest process ([kernel-serve](kernel-serve.md)), a transport to the page ([port-streams](port-streams.md)), a way to hold and name many namespaces (this proposal), and a build that leaves the rest out (this proposal).

## Proposal

### What's in the build

| Kept | From |
| --- | --- |
| Channels, walks, mount tables, the device switch, the `sys*` wrappers | drawterm `kern/`: `chan.c`, `pgrp.c`, `dev.c`, `sysfile.c`, `parse.c`, `error.c`, `data.c`, `alloc.c`, `allocb.c`, `qio.c`, `sleep.c`, `qlock.c`, `rwlock.c`, `waserror.c`, `procinit.c` |
| Namespace copying | `pgrpcpy` and the Pgrp parts of `src/kern/proc.c`, moved to `src/kern/ns.c` so both builds share them |
| Devices | `#/` devroot, `#M` devmnt, `#|` devpipe, `#s` devsrv, `#O` overlay, `#ℏ` devhstream (WebSockets and ports), `#ℓ` dotl, and the new `#N` |
| Server | [kernel-serve](kernel-serve.md)'s `kserve.c` |
| Runtime | web: `os-wasm.c`, `coro.c`, `stack.S`, `io.zig`; native: drawterm's `posix.c` |
| libc, libsec | drawterm's, for `fmt`, `convM2S`/`convS2M`, `cleanname`, and what dotl and hstream use |

Left out: `src/vmm/`, `hcpu`, the JIT, loaders, segments, `syscall.zig`, `src/linux/`, devproc, devcons, devhcons, devenv, devdup, devip, devdraw and graphics, devlinux, `#H` and the built-in root, devfs on the web (there's no host tree; native builds keep `#U` behind an option), `machine.zig`'s run loop, the CLI, and the policy's plan. Nothing in the kept list changes for h9 machines.

### Namespaces: `#N`

`#N` is bound at `/ns` in the control namespace (below). Its tree:

```text
/ns/clone        open: a new namespace; read: its id
/ns/N/ctl        write: bind, mount, unmount, cd, clear lines; read: the id
/ns/N/ns         read: the mount table, as /proc/n/ns reads on 9front
```

- **Making one.** Opening `clone` makes namespace N, empty, and the open fid is N's `ctl`. The first write may be `copy P`, which makes N a copy of namespace P's mount table (`pgrpcpy` with `RFNAMEG`) and its root and `dot`, or `empty`, the default. An empty namespace's `/` is a fresh bare `#O`: an in-memory directory tree, writable, so the host can make mount points with ordinary 9P `Tcreate`s before binding onto them.
- **Composing.** Each line written to `ctl` is one newns operation, parsed by `src/newns.zig` and run against N's Pgrp, with paths resolved in N: `bind [-abcC] old new`, `mount [-abcC] dial new [spec]`, `unmount [old] new`, `cd dir`, `clear`, and `board` (see Boards). A `mount`'s dial is `srv!NAME`, a server on the host's board (below), a path to a `/srv` entry in N itself, a `port!NAME` ([port-streams](port-streams.md)), or a `ws://` or `wss://` URL ([websocket-9p](websocket-9p.md)), every one through a `#ℓ` conversation, so 9P2000 and 9P2000.L servers both work. `bind '#O' x` makes a fresh in-memory overlay over `x`, as in `--ns`, which is how a host gets a ramfs or a copy-on-write layer over a read-only tree. A failed line fails its write with the kernel's error, and the lines before it stand.
- **Reading.** `ns` lists N's mounts in newns syntax, so a namespace can be saved and replayed into another.
- **Lifetime.** A namespace lives while its `ctl` is open or any served fid is attached to it. `ctl` takes `hold`, which keeps it alive with neither, until `free`. Freeing closes its Pgrp; channels into servers it mounted are clunked.
- **Ids** are decimal and never reused within a kernel's life.

### The control namespace

Namespace 0 is made at boot and can't be freed. Its `/` is devroot with `ns` (`#N`), `srv` (`#s`), and `tmp` (a bare `#O`). Every other namespace has `#N` masked (Pgrp's device mask), copied or not, so a task handed its namespace can't reach `/ns` and compose or attach to others.

### Boards

Namespace 0's `/srv` is the *host's board*: the host posts trees there once (`/srv/opfs`, `/srv/idb`) and shares them per namespace. A `ctl` line's `srv!NAME` dial always reads the host's board, whatever N can see, so `mount srv!opfs /mnt/opfs` written to N's `ctl` mounts the host's OPFS tree into N alone.

Every other namespace starts with no board: `#s` is masked in it along with `#N`, and a `/srv` copied from 0 is unmounted from the copy. A namespace that wants a board of its own, for its own processes to rendezvous on, gets one with `ctl`'s `board` line, which binds a fresh, empty devsrv board at `/srv` in N. The kernel attaches it directly, so the mask, which stops only `#s` paths resolved in N, doesn't refuse it. Nothing posted there is visible to the host's board or to any other namespace, and the board goes away with N.

### Serving

The kernel serves 9P2000 with [kernel-serve](kernel-serve.md)'s server and its named-namespace source: `Tattach`'s `aname` is a namespace id, and the empty name is 0. The host attaches to 0 for control and to N for each task. 9P2000.L clients go through dotl's server side, as serve's dialect slot does.

### The JS API

`h9ns.js` exports:

```js
const k = await createNamespaceKernel({ wasm, memory });  // starts the Worker
k.addPort(name, port);          // a 9P server the kernel can mount as port!name
k.removePort(name);
const p = k.connect(aname = ''); // a MessagePort served by kserve, attached to aname
k.terminate();
```

That's the whole API. Making and composing namespaces is 9P on a connection to `''`: walk to `/ns/clone`, open it, write `copy 3` and `bind ...` lines, read the id. A small 9P2000 client for tests and examples ships in `tests/web/`; Wanix's host module has its own.

A task runner hands a namespace to an h9 machine with port-streams:

```js
const ctl = await nine.open(k.connect(''), '/ns/clone', ORDWR);
await ctl.write('copy 0\n');           // or build it line by line
const id = (await ctl.read()).trim();
const m = await createMachine({ root: k.connect(id) });
```

The machine builds its own namespace over that root (devices, `/tmp`, the Linux view) as over any 9P root. Binds the host later writes to N's `ctl` are seen by the machine on its next walk; binds made inside the machine stay in the machine.

### The native API

`libh9ns.a` and `h9ns.h`:

```c
int h9ns_boot(void);
int h9ns_serve(int fd, const char *aname);   /* serve 9P2000 on fd until it closes */
int h9ns_addfd(const char *name, int fd);    /* a 9P server the kernel can mount as fd!name */
```

It's for native Wanix hosts and for testing the kernel without a browser. The native build keeps `#U` behind `-Dnskernel-hostfs` for embedders that want to lend host directories.

### Build

`zig build nskernel` installs `zig-out/nskernel/`: `h9ns.wasm` and `h9ns.js` for wasm32-wasi, and `libh9ns.a` and `h9ns.h` for the host target. `zig build nskernel-test` runs the cases under Node.

## Rationale

**A build, not a mode of h9.** An h9 machine with no program would carry the CPU, JIT, loaders, and personalities, which are most of `h9.wasm`, for nothing. A separate build also keeps the namespace kernel's surface reviewable: no system call tables means no guest-supplied pointers.

**One Pgrp per namespace, not a Proc per namespace.** A namespace in drawterm is a Pgrp, and kserve sets `up->pgrp` per request. A Proc per namespace would only park.

**A device and a ctl file, not new 9P messages.** 9P has no bind. A clone file and newns lines are how Plan 9 already spells it (`/proc/n/ns` reads it, `newns` writes it), any 9P client can use them, and `ns` round-trips with `ctl`.

**Empty means a bare `#O`.** Wanix's commonest root is a fresh ramfs. A devroot-style fixed skeleton would need a list of mount points; an in-memory tree lets the host make whatever it binds onto.

**A board per namespace, not one shared `/srv`.** Shared is Plan 9's model and the simplest for the host, but everything in the namespace kernel runs as one user, so devsrv's permission bits don't stop a task from opening, removing, or squatting on another's entries, and a shared board would be a back channel around per-task composition. The host's board keeps "post once, mount into many", and `srv!` mounts make each share explicit. h9 machines bind their own `#s` at `/srv` anyway, so they lose nothing.

**`#N` masked outside the control namespace.** A task's namespace is handed to code the host doesn't trust (a Linux program in a machine). Being able to clone and attach to other namespaces from inside would undo the isolation per-task namespaces exist for.

**9P only at the boundary.** Wanix's duplex RPC maps to JavaScript and Go APIs, which is what the host module offers its users; inside, it would be a second protocol for the kernel to parse. 9P2000 is what devmnt, kserve, h9 machines, and native h9 all speak, so the namespace kernel composes with all of them without translation.

**A Worker, not the page.** The kernel blocks only on 9P replies, so it could run on the page, but a slow walk or a large copy would block the UI, and a fault would take the page down. A Worker keeps it isolated. A SharedWorker, so tabs share namespaces, is an open issue.

## Compatibility

- **h9 machines:** unchanged. `pgrpcpy` moves to `src/kern/ns.c`, `#N` isn't in their device table, and kserve is shared with [kernel-serve](kernel-serve.md).
- **Build:** new steps `nskernel` and `nskernel-test`, and new release artifacts `h9ns-<version>.tar.gz` (the web files) and the native library. h9 stays MIT.
- **`third_party/`:** unchanged; the build selects files.

## Security

- **The kernel's reach** is what the host hands it: ports, WebSocket URLs, and (natively, by option) host directories. It dials nothing on its own. A `ws://` mount is the page's WebSocket, under the page's own origin rules; there's no net policy, since the host decides every mount.
- **Isolation between namespaces** is Plan 9's: a namespace reaches only what's bound or mounted into it. `#N` and `#s` are masked outside the control namespace, so a task can't open, remove, or squat on what the host posted, and can't post anything another task will find. The host shares a posted tree with a namespace only by writing a `srv!` mount to its `ctl`.
- **Untrusted clients:** a task's port is served by kserve, which bounds and validates every message. A client attached to N can't name another id, since the attach name is fixed by the host's `connect`.
- **Memory:** one linear memory for every namespace and in-memory tree. `memory` caps it; a write past it fails with the kernel's allocation error.

## Done criteria

- [ ] `zig build nskernel` builds `h9ns.wasm` with none of the left-out objects linked, and its size is recorded here.
- [ ] Under Node: clone a namespace, `bind '#O' /`, create `/a/b`, `mount port!x /n/x` against a JS 9P server, and read a file through a second attach.
- [ ] In Chromium, with no COOP or COEP headers, an h9 machine runs `ls /n/x` with its root served by the namespace kernel from another Worker.
- [ ] Cases tagged `[namespace-kernel]`:
  - `test "a copied namespace keeps its parent's mounts [namespace-kernel]"`
  - `test "an empty namespace's / is writable and in memory [namespace-kernel]"`
  - `test "ctl lines bind, mount and unmount in that namespace only [namespace-kernel]"`
  - `test "ns reads back lines ctl replays into an equal namespace [namespace-kernel]"`
  - `test "a 9P2000.L server mounts through ctl [namespace-kernel, dotl]"`
  - `test "a namespace is freed when ctl and every attach close [namespace-kernel]"`
  - `test "/ns isn't reachable from a task's namespace [namespace-kernel]"`
  - `test "srv!opfs in a ctl mounts the host's board entry into that namespace only [namespace-kernel]"`
  - `test "a task's board line gives it a private /srv [namespace-kernel]"`
  - `test "a bind written after a machine starts is seen by it [namespace-kernel, port-streams]"`
  - `test "the native library serves the same tree [namespace-kernel]"`

## Implementation

1. Move `pgrpcpy` and the Pgrp helpers to `src/kern/ns.c`; build the kernel subset for wasm32-wasi and native, with stubs where a kept file references a left-out one.
2. `#N`: clone, boards and `srv!`, ctl through `newns.zig` (its replay loop moves out of `machine.zig` so both builds run it), ns, lifetime, the control namespace, the device mask.
3. Serving through [kernel-serve](kernel-serve.md)'s named source; `h9ns.js`'s Worker, `connect`, and `addPort` on [port-streams](port-streams.md)' JS host code.
4. The native library and its API.
5. The Node and Chromium cases, release artifacts, and SPEC.md.

## Open issues

- **Sharing across tabs.** A SharedWorker would let tabs of one origin share live namespaces. JSPI and `MessagePort`s work there, but whether each browser lets a SharedWorker run long-lived wasm needs checking.
- **Shared boards between chosen namespaces.** Two tasks that should rendezvous (a server task and its clients) each get a private board today, and the host relays by posting to its own. A `board N` line that binds namespace N's board into another would let the host pair them directly.
- **Persistence.** OPFS and IndexedDB trees are the host's to serve. Should the kernel offer an on-disk format for `#O`'s upper layer, so a namespace's writes survive a reload without a host-side server?
- **Wanix's `#` names.** Wanix spells devices `#web`, `#task`, and so on, and drawterm's device names are one rune. The host module maps them to paths; whether the kernel should accept longer names is left to Wanix's design.
