# The namespace kernel

This describes, as built, the namespace kernel (`nskernel`): a build of h9's kernel with nothing for running programs, for the web host and as a native library. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec, and [host-web.md](host-web.md) describes the web host it runs on in a page.

## Contents

- [The build](#the-build)
- [Namespaces and `#N`](#namespaces-and-n)
- [Serving](#serving)
- [The JS API](#the-js-api)
- [The native API](#the-native-api)

## The build

`zig build nskernel` builds drawterm's channels, mount tables, and devmnt with a handful of devices and none of a machine: no engine, CPU, loaders, segments, system call tables, ABIs, devproc, devenv, or console ([namespace-kernel](../design/epoch-0/namespace-kernel.md)). Its root is `src/nskernel.zig`, built with the `nskernel` option, which keeps `kern.zig`'s exports to what the kept C calls; `src/kern/nstab.c` replaces `devtab.c` and `devcons.c` and stubs what the kept files reference in left-out ones. The device table is `#/`, `#|`, `#M`, `#O`, `#s`, `#ℏ`, `#ℓ`, and `#N`, with `#φ` (host descriptors) natively and `#U` behind `-Dnskernel-hostfs`. `zig-out/nskernel/` gets `h9ns.wasm` (wasm32-wasi, on the web host's coroutines; about 740 KB ReleaseSmall, 200 KB gzipped), `h9ns.js`, `h9ns-worker.js`, the JS files they import, `libh9ns.a`, and `h9ns.h`. `pgrpcpy` lives in `src/kern/pgrp.zig`, which both builds compile. Its `memccpy` is `src/kern/memccpy.c`'s on wasm as on musl, since Zig's wasi-libc one has the same bug.

`zig build nskernel-test` runs `tests/nskernel.zig` against the native library, over socketpairs with `tests/ninep.zig`'s client, then `tests/web/nskernel.mjs` under Node 24 or later, which drives `h9ns.js` with `tests/web/ninep.mjs`'s 9P2000 client and in-memory server; an older Node skips it.

## Namespaces and `#N`

A namespace is a Pgrp, a root, and a dot, in `src/kern/devns.c`. `#N` is `clone`, and `N/ctl` and `N/ns` for each live id. Opening `clone` makes an empty namespace, whose root is a fresh bare `#O` the host can create in, and the fid becomes its `ctl`; reading `ctl` gives the id. Lines written to `ctl` (at most 8 KiB a write, one per line, blank and `#` lines skipped) run one at a time per namespace, each on a kernel process of its own, in that namespace:

| Line | Effect |
| --- | --- |
| `copy P` | First line only: the namespace becomes a copy of P's mount table, root, and dot. A copy of 0 has `/ns` and `/srv` unmounted. |
| `empty`, `clear` | `empty` keeps the fresh root; `clear` empties the mount table in place. |
| `bind`, `mount`, `unmount`, `cd` | newns syntax (`src/newns.zig`), through the Zig leaf `h9_ns_ctl`. `bind '#O' /x` binds a fresh bare overlay, which takes creates. A mount's dial is `srv!NAME` (namespace 0's board), `port!NAME` (a port the host added), `fd!NAME` (natively, a descriptor given to `h9ns_addfd`), `ws://` or `wss://`, or a path; a port, fd, or WebSocket dial goes through a `#ℓ` conversation, so a 9P2000.L server mounts too. |
| `post NAME DIAL` | Posts a dialed server as NAME on the namespace's board: namespace 0's is the root board, the host's. |
| `board` | A private board: a child board of the host's (`#s/clone`), bound at the namespace's `/srv`, whose lease the namespace holds. |
| `hold`, `free` | Keep the namespace alive with nothing open, and drop that hold. Namespace 0 can't be freed. |

`ns` reads the mount table back in newns syntax, with the dial strings mounts were made with (recorded by devmnt channel), so its lines replay into an equal namespace. A namespace is freed when its last `ctl`, attach, and hold go; ids aren't reused. Namespace 0, the control namespace, has `#N` at `/ns`, the root board at `/srv`, and a bare `#O` at `/tmp`; every other namespace masks `#N` and `#s`.

## Serving

The kernel serves 9P2000 with kserve's named source (`h9_kserve_newnamed`): an attach name is a namespace id, the empty name 0, and a connection made for one id (`h9_kserve_connas`) refuses any other. Each attach holds its namespace. Connections reach the server Proc through a queue (`h9_ns_post`, from any thread), and each goes through a `#ℓ` conversation's server side, so 9P2000.L clients are translated.

## The JS API

`h9ns.js`'s `createNamespaceKernel({ wasm, memory })` starts `h9ns-worker.js` in a Worker (a `worker_threads` Worker under Node), which runs `h9ns.wasm` with `h9-web.js`'s `run`, an empty tree for WASI, and no console, and resolves once it's running. `memory` caps the linear memory, in bytes. `addPort(name, port)` and `removePort(name)` manage the ports `port!NAME` dials, as a machine's `Ports`; `connect(aname)` makes a `MessageChannel`, hands one end to the Worker, and returns the other, served 9P2000 attached to `aname`. The Worker passes it to `Ports.serve(port, aname)`, and the kernel's port loop reads each accepted port's name with the `port_aname` import before its stream is served. `terminate()` ends the Worker.

## The native API

`libh9ns.a` and `h9ns.h`: `h9ns_boot()` starts the kernel and namespace 0, once; `h9ns_serve(fd, aname)` serves a host descriptor, which the kernel takes, and returns once serving has started; `h9ns_addfd(name, fd)` names a descriptor that `fd!NAME` mounts dial a duplicate of; `h9ns_error()` says why the last call failed.
