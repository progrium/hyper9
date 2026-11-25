---
slug: fd-mounts
title: Mounting a 9P connection from a host descriptor
status: draft
created: 2026-11-22
authors: [progrium]
depends: [mounts, dotl]
areas: [api, kern, tests]
branch: [fd-mounts]
---

# Proposal: Mounting a 9P connection from a host descriptor

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

An embedder that serves 9P in its own process, such as uitreefs, should be able to hand h9 the connection directly, rather than listening on a unix socket for h9 to dial. [mounts](mounts.md) gives `Machine.Options.mounts` an `.fd` kind for "a connection the embedder already holds", but h9 passes its number to `#ℓ` as a kernel fd, which an embedder has no way to make. This proposal makes `.fd` what mounts meant: a host descriptor, a POSIX fd or a Windows `HANDLE`, that h9 duplicates and wraps as a kernel channel before the `#ℓ` conversation starts. An optional `.fd_write` takes the other end of a pipe pair, so an embedder on Windows, where unix-socket mounts aren't supported, can serve a machine over two anonymous pipes. The CLI, `--print`, and the browser host don't change.

## Background

- **What `.fd` does now.** `Machine.connectUrl` (`src/machine.zig`) sends `fd N` to a new `#ℓ` conversation's ctl file, and devdotl (`src/kern/devdotl.c`) calls `fdtochan(N, …)`, which looks N up in the calling process's kernel fd table. A number from the host's fd table names some other kernel file, or nothing. Nothing in the repository makes an `.fd` mount, and [docs/embedding.md](../docs/embedding.md) describes it as taking "a connection you already hold", which it can't.
- **How a unix socket gets in.** For `unix://`, `h9_unixdial` (`src/kern/rootdial.c`) connects on the host, wraps the socket with devlfd's `lfdchan`, gives it a kernel fd with `newfd`, and `connectUrl` passes that fd to `#ℓ`. That's the whole path a host descriptor needs, minus the `connect`.
- **The relay.** An in-process server today listens on a unix socket in a temporary directory, and the embedder passes `unix:///PATH` as an `.url` mount. That's a file on disk, a cleanup at exit, a path length limit, and a listener another local process could connect to first.
- **Windows.** `h9_unixchan` refuses Windows: a winsock `SOCKET` isn't a handle `ReadFile` and `WriteFile` work on, and those are what devlfd-win32 calls. They do work on pipe handles: drawterm uses devlfd-win32 for a host command's stdio pipes (`third_party/drawterm/kern/win32.c`).
- **One channel per conversation.** A `#ℓ` conversation reads and writes one server channel, `cv->srv`. A socket or a duplex named pipe is one descriptor; a pipe pair is two.

## Proposal

### `Mount.fd` and `Mount.fd_write`

`Machine.Mount`'s `fd: i32 = -1` becomes:

```zig
/// An `.fd` mount's connection: a descriptor in the host process,
/// read from and, without `fd_write`, written to.
fd: ?std.posix.fd_t = null,
/// The descriptor written to, for a pipe pair. Null for a socket or a
/// duplex pipe.
fd_write: ?std.posix.fd_t = null,
```

`std.posix.fd_t` is an `i32` on POSIX hosts and a `HANDLE` on Windows. An `.fd` mount needs `fd`, and `fd_write` is only for `.fd`; either mistake is a usage error (`PolicyConflict`, with `conflict` naming the field). Everything else about the mount is as for `.url`: any destination, `/srv/NAME` to post without mounting, `spec`, `user`, `auth`, `index`, the access options, and the stacks' rules for `/` and `#L`. With `up` on `/` or `#L`, the embedder's server holds the machine's writable layer ([upper-layers](upper-layers.md)), as a page's `MessagePort` does on the browser host ([port-streams](port-streams.md)), so an embedder can keep a machine's changes in its own store.

```zig
var sv: [2]std.posix.fd_t = undefined;
_ = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
try myfs.serveOn(sv[1]); // any 9P2000 or 9P2000.L server, on a thread
var m = try h9.Machine.init(gpa, io, .{
    .mounts = &.{.{ .kind = .fd, .fd = sv[0], .dst = "/n/ui" }},
});
```

On Windows, the same with `CreatePipe` twice:

```zig
.mounts = &.{.{ .kind = .fd, .fd = from_server_read, .fd_write = to_server_write, .dst = "/n/ui" }},
```

### The embedder keeps its descriptors

At the start of each run, h9 duplicates `fd`, and `fd_write` if given (`fcntl(F_DUPFD_CLOEXEC)` on POSIX, `DuplicateHandle` on Windows), and the run's channels own the copies. The embedder's descriptors stay open and stay the embedder's to close, after the run and after `Machine.deinit`. A duplicate that fails is `NamespaceFailed`, with the OS's error in the message, as a failed dial is.

So a server sees each run start with `Tversion` on the same stream, which resets the session, as 9P allows. It doesn't see end of file when a run ends, since the embedder still holds its end.

### In the kernel

h9 duplicates the descriptors in Zig, in `connectUrl`'s `given` path, so the kernel makes no host call for them. `h9_hostfdchan(rd, wr)` in `src/kern/rootdial.c`, beside `h9_unixchan`, takes the duplicates and wraps each with `lfdchan`, and `h9_hostfddial` gives the channels kernel fds with `newfd`, as `h9_unixdial` does. It's built on every native host, Windows included. On the browser host it fails with "host descriptors need a native host", and `.port` is the way in there.

devdotl's ctl takes a second fd: `fd R W` reads the server from R and writes it to W, kept as `cv->srv` and a new `cv->srvw`, which defaults to `cv->srv`. `fd N` is unchanged, so every caller of it today works as before.

`connectUrl`'s `given` path duplicates the descriptors, calls `kern.hostFdDial` with the duplicates, and passes the kernel fds it returns to `#ℓ`, closing them after, as the unix path does with `unixDial`'s.

### Windows handles

A pipe handle, anonymous or named, opened without `FILE_FLAG_OVERLAPPED`, works as `fd` or `fd_write`. A duplex named pipe is one handle and needs no `fd_write`. A winsock `SOCKET` is refused before the run, with "an .fd mount on Windows takes pipe handles, not a socket": h9 tells them apart with `getsockopt(SO_TYPE)`, which succeeds only on a socket. An overlapped handle fails its first read with the OS's error, through the conversation's hangup.

### `--print` and the CLI

An `.fd` mount has no address, so its plan line can't replay. `--print` writes it as a comment, `# mount: an embedder's connection on /n/ui`, so the rest of the output still replays. The CLI has no flag for it.

## Rationale

**Fix `.fd`, rather than add a kind beside it.** [mounts](mounts.md) and the embedding guide already promise `.fd` as a held connection, and no caller can use the kernel-fd meaning, since embedders don't see kernel fds. A second kind, `.handle`, would leave `.fd` documented, unusable, and in the way.

**Duplicate, not take.** Taking the descriptor would make the embedder's copy dangling after the first run, and a `Machine` runs many times on one set of options. Duplicating keeps ownership simple: each side closes what it opened.

**A pipe pair, not only a duplex handle.** `CreatePipe` is the easiest way to get a byte stream on Windows, and it's what a Go or C# server gets from its standard library without named-pipe naming or security descriptors. Supporting the pair costs devdotl one more channel pointer.

**devdotl, not a two-handle devlfd.** A pair could be one devlfd channel with both handles in `aux`, but devlfd is drawterm's, in `third_party/`, and its POSIX and Windows halves would both change. devdotl is h9's own, and the conversation is the only reader of the channel.

**Keep the relay working.** `unix://` stays for servers in another process. An `.fd` mount is for a server whose stream the embedder already has: in-process, or a child it spawned with a socketpair.

**Not devhstream.** devhstream carries a host-made stream through a host thread that pumps it, for WebSockets that need framing and TLS. A raw descriptor needs no pump: devlfd already reads and writes it from the conversation's kproc.

**Duplicating in Zig, not in the kernel.** [host-handles](host-handles.md) moves every host call out of `src/kern/`, so the kernel only wraps descriptors it's given. Duplicating in `connectUrl` keeps `rootdial.c`'s new code to the wrap, and under host-handles an `.fd` mount's descriptor is one more handle the embedder puts in the machine's host table.

## Compatibility

- **`Machine.Options`:** `Mount.fd` changes type from `i32` to `?std.posix.fd_t`, and `Mount.fd_write` is new. There are no `.fd` users to break, inside or outside the repository.
- **CLI, exit codes, and `--print`:** unchanged, except that a plan with an `.fd` mount prints it as a comment.
- **Sandbox defaults:** unchanged.
- **The root tree:** unchanged.
- **`third_party/`:** none. devlfd is used as it is.
- **devdotl:** `fd R W` is new; `fd N`, `serve`, `dial`, and `redial` are unchanged.
- **Docs:** the embedding guide's 9P section gets the examples above, and the Options table's `mounts` row says what `.fd` takes.

## Security

The guest reaches nothing new: an `.fd` mount is a 9P tree, as an `.url` mount is, and the embedder chose to give it. h9 makes no connection of its own, so the network policy has nothing to check, as for a unix socket the CLI dials. Removing the relay removes a listening socket another local process could connect to. An `.fd` mount of another machine's served `/net` reaches that machine's network, its loopback included ([virtual-loopback](virtual-loopback.md)), as importing any machine's `/net` does; the embedder chose to hand it over. Duplicates are made close-on-exec, and are closed when the run ends, so a host command h9 runs doesn't inherit them.

## Done criteria

Integration cases, in `tests/backends.zig`, with a test 9P server on the other end of the stream (`tests/dotlserver.zig`'s, for 9P2000.L):

- [x] `test "an .fd mount serves / from a socketpair the embedder holds [fd-mounts]"`
- [x] `test "an .fd mount at /n/x and at /srv/x, with spec and user [fd-mounts]"`
- [x] `test "an .fd mount with fd_write serves 9P over a pipe pair [fd-mounts]"`
- [x] `test "an .fd mount with up on / keeps the guest's writes in the embedder's server [fd-mounts, upper-layers]"`
- [x] `test "the embedder's descriptor stays open, and a second run uses it [fd-mounts]"`
- [x] `test "an .fd mount without fd, or fd_write on another kind, is PolicyConflict [fd-mounts]"`
- [x] `test "a 9P2000.L server works through an .fd mount [fd-mounts]"`
- [ ] `test "an .fd mount on Windows serves 9P over two anonymous pipes [fd-mounts]"`
- [ ] `test "an .fd mount on Windows refuses a SOCKET [fd-mounts]"`
- [x] `test "--print writes an .fd mount as a comment, and the rest replays [fd-mounts]"`

## Implementation

1. `h9_hostfdchan` and `h9_hostfddial` in `src/kern/rootdial.c`, built on Windows too, with the stubs in `src/kern.zig` for the browser host, and `kern.hostFdDial`.
2. `fd R W` in devdotl's ctl, with `cv->srvw` for writes.
3. `Mount.fd` and `Mount.fd_write`, their checks in `policy.zig`, `connectUrl`'s `given` path, and the `--print` comment.
4. The Windows socket check.
5. The cases above, and the embedding guide.

## Updates

- 2026-11-25: Built on the `fd-mounts` branch, as Implementation describes, with the cases in `tests/backends.zig` against a small 9P2000 server in memory (`tests/fdserver.zig`) and, for 9P2000.L, src/dotl/testserver.zig's, both on the test's end of a socketpair or of two pipes. They pass on the emulator, T1 and T0, on Linux x86\_64. The Windows cases are written and build for `x86_64-windows-gnu`, and wait on CI's Windows runner. The first open issue was real: a reader left in the host's `read` on a run's duplicate took the next run's replies. A conversation over a devlfd channel now waits for the descriptor to be readable first, in a wait that the conversation's last close wakes (`h9_hostwait` in `src/kern/rootdial.c`): `poll` with a wake pipe on POSIX, and on Windows, where a pipe handle can't be polled, `PeekNamedPipe` with a sleep of up to 8 ms when it's empty. That covers a unix socket root whose path has a comma too. The conflicts say which field: `fd: an .fd mount needs one`, and `fd: only an .fd mount takes it` or the same for `fd_write`.

## Open issues

- **Ending a run while the reader waits.** The conversation's kproc blocks in the host's `read` or `ReadFile`. Closing h9's duplicate doesn't wake it on POSIX, and `shutdown` would end the embedder's stream too. The unix-socket path has the same wait, so whatever ends a run there should work here; if it doesn't, the kproc can poll with a wake pipe, or use `CancelSynchronousIo` on Windows.
- **Redials.** An `.fd` conversation has nothing to redial, so a 9P2000.L.Z server that drops it hangs up the mount, as a lost unix socket without a path would. An embedder that wants reconnects could give a callback that returns a new descriptor.
- **Serving over a descriptor.** port-streams gives the page `machine.serve(port)`, and devdotl already takes `serve N`. An embedder holding a stream could hand it over the same way, as `Machine.serveFd(fd, fd_write)`, to serve the machine to an in-process client. It would go through serve's per-connection path as an accepted stream, under its caps and `/net` rule, and [kernel-serve](kernel-serve.md) would make it cost no guest process.
- **`fd://N` on the CLI.** A parent that spawns `h9` could pass a socketpair as an inherited fd with `--url fd://3:/n/ui`. It's cheap on POSIX, but it puts a descriptor number in the plan, and Windows would need an inheritable handle's value on the command line.
