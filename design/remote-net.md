---
slug: remote-net
title: Linux sockets on whatever /net is mounted
status: draft
created: 2026-11-10
authors: [progrium]
depends: [12, 21, 35, 50]
areas: [kern, linux, web]
---

# Proposal: Linux sockets on whatever /net is mounted

## Abstract

The [Linux personality](0050-linux-net.md)'s sockets open `/net` through the process's namespace instead of `#I` by name, and work on a conversation from any server, not only devip's. So a `/net` mounted from another machine, such as a host h9's served with [serve](0035-serve.md)'s `--serve-net`, is the network for Linux programs as it already is for Plan 9 programs. On the [browser host](0012-browser-host.md), `wsmount -b ws://HOST:PORT/ /net` then gives busybox, Python, and Go programs the host's network. A conversation that isn't devip's gets a kernel reader that reads ahead into a queue, so poll, epoll, non-blocking sockets, and `MSG_PEEK` work on it. No flags, `Machine.Options` fields, or page options are added.

## Background

- **Serving `/net` already works.** `h9 --serve ws://127.0.0.1:5640/ --serve-root /net --serve-net` exports a machine's devip, `cs` included, under its own `--net` and `--net-allow`, with `--serve-origin` and `--serve-token` checked at the handshake.
- **Plan 9 programs already use a mounted `/net`.** In the browser guest, `wsmount -b ws://127.0.0.1:5640/ /net` puts the host's `tcp`, `udp`, and `cs` before `/net/ws`, and a `dial(2)` goes through the host. This was checked in Chromium against the demo page, and natively with a client whose `--net-allow` allowed only the listener. The mask on `#I` doesn't stop it, since a mount isn't a `#` attach.
- **Linux programs don't.** `src/linux/sys.zig` opens `#I/tcp/clone`, `#I/udp/clone`, and a conversation's files by device name, so it never sees the mount. It recognizes a socket by its channel being devip's (`convOf`), and `src/kern/linuxnet.c` gets readiness, `MSG_PEEK`, `MSG_DONTWAIT`, and `SO_ERROR` from the conversation's host socket (`h9_ip_sfd` and `h9so_*`). A channel from devmnt has no host socket, and `chanready` reports it always ready, so a non-blocking read would block.

## Proposal

### Opening `/net` through the namespace

`socket(2)` opens `/net/tcp/clone` or `/net/udp/clone` with the process's namespace, as `dial(2)` does, and a conversation's other files by the same directory: the clone's path with `clone` replaced by `N/ctl`, `N/data`, `N/local`, `N/remote`, `N/status`, or `N/listen`. Natively `/net` is `#I` unless the program or a namespace file binds something else there, so nothing changes. Under `--net=disable`, `/net` has no `tcp`, and the open fails with `EACCES`, as it does now.

The socket's state (`Sock`) is keyed by the data channel's qid path and device, not by devip's conversation number, so conversations from two servers can't collide. `convOf` becomes "the conversation directory behind this fd", which it gets from the channel's path (`/net/tcp/4/data`), for devip's channels and devmnt's alike. A fd that isn't a conversation's `data` is `ENOTSOCK`, as now.

### Two kinds of conversation

- **devip's (`#I`).** As now: the host socket behind it answers readiness, peek, non-blocking calls, and `SO_ERROR`, and the watcher wakes pollers.
- **Any other server's.** The data channel is all there is, so the kernel keeps a small stream for it, made when the Linux layer first makes or finds the socket:
  - **Receive.** A kernel process reads the remote `data` into a qio `Queue` of 64 KiB, and stops while it's full. `recv` reads from the queue, `MSG_PEEK` copies without consuming, and `MSG_DONTWAIT` returns `EAGAIN` when it's empty. A read of 0 closes the queue: `POLLIN|POLLRDHUP`. An error closes it with the error: `POLLERR` and `SO_ERROR`.
  - **Send.** A blocking send writes to the remote `data`. A non-blocking send copies into a send queue of 64 KiB, which a second kernel process drains, and returns `EAGAIN` when it's full. `POLLOUT` is ready while it has room.
  - **Readiness.** `chanready` asks the stream's queues, as it does a pipe's, and the queues wake pollers through `h9_qwake`, as pipes do, so `poll`, `select`, and epoll need nothing else.
  - **connect.** A blocking connect writes `connect ADDR!PORT` to `ctl`. A non-blocking one does the write in a kernel process and returns `EINPROGRESS`. Its result is `SO_ERROR`, and `POLLOUT` is ready when it's done.
  - **listen and accept.** `announce` goes to `ctl`. A kernel process opens `listen`, which blocks on the server until a call comes, so a listening socket is readable when a call is waiting, and `accept` takes it.
  - **UDP.** The conversation is put in `headers` mode, so `recvfrom` and `sendto` carry the peer's address in each message, as devip's UDP does.
  - **Options.** `TCP_NODELAY` and `SO_KEEPALIVE` are written to `ctl`, where devip takes them, and the rest are recorded and ignored, since the server owns the socket.
  - **Close.** Closing the fd's last reference closes the data channel, which hangs up the server's conversation, and ends the kernel processes.
- **Addresses.** `getsockname` and `getpeername` read `local` and `remote`, for both kinds.

### Names

Linux programs resolve names themselves, from `/etc/hosts` and `/etc/resolv.conf`, with UDP to the nameserver, so a mounted `/net/udp` serves them with no change. `cs` isn't involved.

### Policy

The policy of the machine that serves `/net` governs what its conversations reach: its `--net` and `--net-allow` are checked by its devip, as for any client. The mounting machine's `--net` governs whether it can reach the server at all, through `/net/ws` or `/net/tcp`. Its `--net-allow` isn't applied to the served conversations, since their connects are writes to a mounted file, as it isn't for Plan 9 programs today. The plan lists nothing new.

## Rationale

**No flag.** The machine already has a way to say where its network is: whatever is mounted on `/net`. Plan 9 programs follow it, and with this change Linux programs do too, so the same `wsmount -b` works for both, and a namespace file can set it up at boot. A `--net-via URL` flag was drafted first, building devip's socket layer on the web host over a served `/net`. It was dropped: it added a flag, an option, and a page option for what a mount already says, and only worked on the web host.

**In the Linux layer, not devip.** Making the queue a property of the conversation, rather than of a device, lets it work for any server: a host h9's devip, another 9front machine's `/net` through `import`, or a userspace network stack serving `/net`.

**A queue per remote socket.** devmnt can't say whether a read would block, and 9P has no readiness. A read ahead into a queue is how Plan 9's own `aux/` relays do it, and qio already wakes pollers.

## Compatibility

No CLI flags, exit codes, `Machine.Options` fields, or page options change. Natively `/net` is `#I` by default, so a Linux program sees the same sockets. A program that binds its own `/net` now changes what its Linux children's sockets reach, as it already did for Plan 9 children. `third_party/` is unchanged.

## Security

Nothing new is reachable without a mount the guest makes itself, through a network it was already allowed. A served `/net` is the serving machine's to guard: `--serve-net` is off by default, the plan shows it as a caveat, and a WebSocket listener checks `--serve-origin` and `--serve-token`. The token travels in a page's URL query, so it appears in the host's and any proxy's logs, and the manual says to use one beyond loopback.

## Done when

- `test "a Linux program connects through a mounted /net [remote-net, linux-net]"`
- `test "poll, MSG_PEEK, and MSG_DONTWAIT on a socket from a mounted /net [remote-net, linux-net]"`
- `test "a non-blocking connect on a mounted /net reports through SO_ERROR [remote-net, linux-net]"`
- `test "UDP sendto and recvfrom through a mounted /net [remote-net, linux-net]"`
- `test "listen and accept on a mounted /net [remote-net, linux-net]"`
- `test "the serving machine's --net-allow refuses a mounted /net's connect [remote-net, serve]"`
- `test "Linux sockets follow a /net the program binds [remote-net, linux-net]"`
- The demo page in `?linux` mode, against a host h9 serving its `/net`, fetches a page with busybox `wget` after `wsmount -b`, in `tests/web/browser.mjs`.

## Implementation

1. Open `/net` through the namespace, and key `Sock` by the data channel, in `src/linux/sys.zig`. devip's conversations behave as now; the `[50]` cases pass unchanged.
2. The stream for other servers' conversations in `src/kern/linuxnet.c`: the receive queue and its kernel process, `chanready`'s case, and `h9_linux_sockrecv`'s.
3. Sends, non-blocking connect, `SO_ERROR`, options, and close.
4. listen and accept, and UDP's headers mode.
5. The cases, the browser check, and `wsmount` in the Linux root's reach on the web host.
6. MANUAL.md and SPEC.md. Set `status: implemented`.

## Open issues

- **Serving's process cap.** Each connection's exportfs gets 8 processes, and each remote socket's reader holds one in a blocking read, as does each pending connect or listen. So one `wsmount` carries at most about 7 busy sockets. A client that needs more can mount `/net` over more than one connection, or serve could lift the cap for `--serve-net` connections.
- **`wsmount` from a Linux root.** `wsmount` is an rc script in `#H/bin`. The `?linux` demo's shell is busybox, so the mount has to come from a namespace file, a page option to run it at boot, or an `h9`-provided command a Linux shell can run.
- **Latency.** Every send is a 9P round trip. Small non-blocking writes could be coalesced in the send queue unless `TCP_NODELAY` is set.
