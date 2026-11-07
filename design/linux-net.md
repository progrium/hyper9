---
slug: linux-net
title: Linux readiness and sockets
status: draft
created: 2026-11-05
authors: [progrium]
depends: [18]
areas: [kern, sandbox]
---

# Proposal: Linux readiness and sockets

## Abstract

Linux processes under the [Linux personality](0018-linux-personality.md) can use BSD sockets, non-blocking fds and the readiness calls: `poll`, `ppoll`, `pselect6`, `epoll` and `eventfd`. Sockets are served by `/net`, so the policy's network rules apply unchanged. Readiness is new kernel code in h9: a leaf that asks each fd's channel whether a read or write would block, woken by the queues and host sockets behind it. This brings curl, Python's `asyncio` and `http.server`, Node-style event loops and Go's network poller to h9.

## Background

Plan 9 has no readiness API: a program that wants to wait on several fds uses a process per fd. Linux programs almost all use `poll` or `epoll`, often with `O_NONBLOCK` fds, and treat `EAGAIN` as "try again when ready".

What's behind an fd in h9 decides how readiness can be known:

- **Pipes and the console** are backed by qio `Queue`s. `qcanread` and `qfull` say whether a read or write would block, and the queue's wakeups say when that changes.
- **devip's data files** are not. `Qdata` reads call `so_recv` on a host socket directly (`kern/devip.c`), and `accept` calls `so_accept`. There's no queue to inspect: readiness is the host socket's.
- **devfs files** are always ready, as on Linux.
- **devmnt files** are ready when the server answers, which can't be known without asking.

drawterm's devip (`kern/devip.c`, `kern/devip-posix.c`) is also thinner than 9front's, in ways a Linux socket API reaches:

- **`connect` blocks.** The ctl message calls `so_connect`, a blocking `connect()`. Go and Python's asyncio always connect non-blocking and expect `EINPROGRESS`, then writability, then `getsockopt(SO_ERROR)`.
- **The ctl file takes only `connect`, `announce` and `bind`.** There's no half-close and no socket options.
- **UDP has no addressing.** There's no `headers` mode, so a UDP conversation talks only to the address it connected to, and a read doesn't say who sent it. musl's DNS resolver `sendto`s on an unconnected socket and matches replies by their `recvfrom` address, so every hostname lookup from an Alpine program needs it.
- **Conversations are capped machine-wide** at 30 for TCP and 10 for UDP (`newproto` in `ipinit`). A Go HTTP client pool or a small server passes 30 quickly.

A prototype, which passed Linux sockets and readiness through to host sockets, ran Go's `net/http` server and client and a UDP round trip, and Python's asyncio, `http.server` with `urllib`, and `subprocess` with pipes, on arm64 and amd64. Its record of the calls those made is used below.

## Proposal

### Sockets

`socket`, `socketpair`, `connect`, `bind`, `listen`, `accept4`, `sendto`, `recvfrom`, `sendmsg`, `recvmsg`, `getsockname`, `getpeername`, `setsockopt`, `getsockopt` and `shutdown`, for `AF_INET` and `AF_INET6` with `SOCK_STREAM` and `SOCK_DGRAM`, over `/net` clone files:

- `socket` opens `/net/tcp/clone` or `/net/udp/clone` and keeps the ctl fd with the data fd.
- `connect` writes `connect`, `bind` and `listen` write `announce`, and `accept4` opens the conversation's `listen` file.
- **A non-blocking `connect`** returns `-EINPROGRESS`. devip gains an asynchronous connect: the host socket is connected non-blocking and watched by the host poller (see Readiness), the conversation reports writable when the connection completes or fails, and `getsockopt(SO_ERROR)` reads the result from the conversation's `status`. A blocking `connect` waits for the same thing.
- **`shutdown`** writes a new `shutdown` ctl message (`rd`, `wr` or `rdwr`), served by `so_shutdown`. asyncio's `write_eof` and HTTP clients half-close, and a peer's half-close is what `EPOLLRDHUP` reports.
- **UDP** gains 9front's `headers` mode: after a `headers` ctl message, each write starts with the destination address and port and each read with the source's, so `sendto` and `recvfrom` work on unconnected sockets. musl's resolver needs it.
- `getsockname` and `getpeername` read `local` and `remote`.
- Socket options that h9 can honour (`SO_REUSEADDR`, `TCP_NODELAY`, `SO_KEEPALIVE`, and `TCP_KEEPIDLE`, `TCP_KEEPINTVL` and `TCP_KEEPCNT`, which Go sets on every connection) become new ctl messages in devip; the rest are accepted and recorded, so `getsockopt` returns them. `SO_ERROR` is read from the conversation.
- **Conversation caps** grow from 30 TCP and 10 UDP to limits set by the machine (4096 and 1024 by default), allocated as they're used.
- `AF_UNIX` sockets are served by pipes for `socketpair`, and by `/srv`-style posting for named sockets once [devsrv](0008-devsrv.md) is built; until then, `bind` on `AF_UNIX` is `-EAFNOSUPPORT`.
- DNS goes through the Linux root's `/etc/resolv.conf`, as Linux's libc does (see Open issues).

The policy's devip hooks apply, so `--net=disable` masks sockets entirely (`socket` is `-EACCES`), and [net-policy](0005-net-policy.md)'s rules apply once it's built.

### Readiness in the kernel

A leaf `h9_poll(fds, n, timeout)` in `src/kern/` asks each fd's channel whether it's readable, writable or hung up, and sleeps until one is or the timeout passes:

- **qio-backed channels:** `qcanread`, `qfull` and the queue's closed state. A hook called from qio's existing wakeups wakes pollers on that queue.
- **devip conversations:** the host socket's readiness, from a per-machine host poller thread (`kqueue` on macOS, `epoll` on Linux, `WSAPoll` or IOCP on Windows) watching the `sfd`s pollers ask about. It wakes the pollers when a socket changes.
- **The console:** the console reader's queue, as for other qio channels.
- **devfs files:** always ready.
- **devmnt and other channels:** reported ready, so a read blocks as it would without `poll`. This is wrong for a 9P-served pipe, but right for files.

`poll`, `ppoll` and `pselect6` call `h9_poll` directly. A negative fd in a `pollfd` array is ignored, as on Linux; CPython's selectors pass them. **`epoll`** keeps an interest list per epoll fd, level-triggered and edge-triggered, and `epoll_pwait` calls `h9_poll` on it, filtering edges by a per-entry sequence number bumped on each wakeup. Both modes are on the critical path: Go registers every socket with `EPOLLET|EPOLLRDHUP|EPOLLIN|EPOLLOUT`, and asyncio uses level-triggered `EPOLLIN` and `EPOLLOUT` with frequent `EPOLL_CTL_DEL`. **`eventfd2`** is a small device with a counter, readable when non-zero.

### Non-blocking fds

`O_NONBLOCK`, set at open, with `fcntl`, or with `ioctl(FIONBIO)` (which CPython uses), makes `read`, `write`, `accept4` and `connect` check readiness first and return `-EAGAIN` (or `-EINPROGRESS` for `connect`) instead of blocking. The check and the call aren't atomic: if another reader takes the data in between, the read blocks. For qio channels the check and the read are one step under the queue's lock, a read that takes what's queued and never sleeps, so there's no gap. For sockets it calls the host with `MSG_DONTWAIT`, and a non-blocking `accept4` with nothing pending is `-EAGAIN`.

## Rationale

**Readiness in h9's kernel code, not in a translator.** A translator running as a guest program could only build `poll` from helper processes, one per fd, as linuxemu did. h9 owns the kernel, so it can ask the channels directly.

**Asking host sockets, not adding queues to devip.** A queue in front of each socket would need a reader thread per socket and copy every byte twice. The host already knows when a socket is ready.

**Extending devip rather than going around it.** Async connect, `shutdown`, UDP headers and socket options could be served by host sockets h9 opens itself, beside devip. But then `/net` wouldn't show them, and the policy's devip hooks would need a second home. 9front's own devip has headers mode and more ctl messages, so these edits move drawterm's toward it.

**Hooks rather than vendor changes.** qio's wakeups get one call to a leaf, and devip's conversations expose their `sfd` through a leaf. Where a hook can't be added without editing the vendored file, the edit is one line, marked `h9:`, as devfs's hooks are.

## Compatibility

- **Vendored tree:** a wakeup hook in `qio.c` and an `sfd` accessor for devip, each a line or two, marked `h9:`. devip's changes are larger: an asynchronous connect, `shutdown`, `headers` for UDP, the socket-option ctl messages and growable conversation tables, in `devip.c` and each `devip-*.c`, marked `h9:`. They're worth offering upstream.
- No CLI flags change. `--net` governs sockets as it governs `/net`.

## Security

- **No new reach:** every socket is a `/net` conversation, so `--net` and the policy's devip hooks apply. A Linux program can't open a host socket that a 9front program couldn't.
- **The host poller** watches only sockets devip has already opened for the guest, and never accepts or reads on them itself.

## Done when

Integration cases tagged `[linux-net]`:

- `test "poll on a pipe wakes when the writer writes [linux-net]"`
- `test "epoll edge-triggered on a pipe [linux-net]"`
- `test "O_NONBLOCK read on an empty pipe is EAGAIN [linux-net]"`
- `test "TCP echo between a Linux client and a 9front server [linux-net]"`
- `test "socket under --net=disable is EACCES [linux-net]"`
- `test "eventfd counts and wakes epoll [linux-net]"`
- `test "non-blocking connect is EINPROGRESS, then writable, then SO_ERROR 0 [linux-net]"`
- `test "shutdown(SHUT_WR) shows the peer EOF and EPOLLRDHUP [linux-net]"`
- `test "UDP sendto and recvfrom on an unconnected socket [linux-net]"`
- `test "more than 30 TCP connections at once [linux-net]"`
- `test "Go net/http server and client in one Linux program [linux-net]"`

Demos: `h9 --root alpine curl -sI https://example.com` under the default network policy, and `h9 --net=enable --root alpine python3 -m http.server` serving a page to the host.

## Implementation

1. Sockets over `/net`, blocking only, with devip's `shutdown`, socket options and larger conversation tables. A blocking TCP client and server.
2. `h9_poll` for qio channels, `poll`, `ppoll`, `pselect6`, `O_NONBLOCK`.
3. The host poller for devip, sockets in `h9_poll`, and devip's asynchronous connect. UDP `headers`, and DNS through musl's resolver.
4. `epoll` and `eventfd`. curl and `http.server`.
5. DESIGN.md's Linux personality section gains sockets and readiness.

## Open issues

- **`/etc/resolv.conf`.** DNS needs UDP `headers` (see Sockets) and a resolver address. Alpine's minirootfs has none, and the Linux root is read-only by default. Serving one from the host's resolver needs a place to put it: devlinux can't add a file inside the root's `/etc` without shadowing the rest of it, since Plan 9 unions don't merge below the top. A bind of a devlinux file over an existing one works only if the root has the file. Options: write it into an overlay once [overlay](0011-overlay.md) is built, or have fetch.sh add one to the fixture.
- **Readiness for devmnt.** A 9P server that serves a pipe-like file can't report readiness in 9P2000. A `Tread` with a zero count, or a dotl-style extension, might.
- **`AF_NETLINK`**, which `ip` and some libraries probe, is `-EAFNOSUPPORT`. Is anything common blocked by that?
- **`SO_PEERCRED`** for `AF_UNIX`, and passing fds with `SCM_RIGHTS`, once named Unix sockets exist.
