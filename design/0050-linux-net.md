---
id: 50
slug: linux-net
title: Linux readiness and sockets
status: implemented
created: 2026-11-05
authors: [progrium]
depends: [18]
areas: [kern, sandbox]
---

# Proposal: Linux readiness and sockets

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Linux processes under the [Linux personality](0018-linux-personality.md) can use BSD sockets, non-blocking fds, and the readiness calls: `poll`, `ppoll`, `pselect6`, `epoll`, and `eventfd`. Sockets are served by `/net`, so the policy's network rules apply unchanged. Readiness is new kernel code in h9: a leaf that asks each fd's channel whether a read or write would block, woken by the queues and host sockets behind it. This brings curl, Python's `asyncio` and `http.server`, Node-style event loops, and Go's network poller to h9.

## Background

Plan 9 has no readiness API: a program that wants to wait on several fds uses a process per fd. Linux programs almost all use `poll` or `epoll`, often with `O_NONBLOCK` fds, and treat `EAGAIN` as "try again when ready".

What's behind an fd in h9 decides how readiness can be known:

- **Pipes and the console** are backed by qio `Queue`s. `qcanread` and `qfull` say whether a read or write would block, and the queue's wakeups say when that changes.
- **devip's data files** are not. `Qdata` reads call `so_recv` on a host socket directly (`kern/devip.c`), and `accept` calls `so_accept`. There's no queue to inspect: readiness is the host socket's.
- **devfs files** are always ready, as on Linux.
- **devmnt files** are ready when the server answers, which can't be known without asking.

drawterm's devip (`kern/devip.c`, `kern/devip-posix.c`) is also thinner than 9front's, in ways a Linux socket API reaches:

- **`connect` blocks.** The ctl message calls `so_connect`, a blocking `connect()`. Go and Python's asyncio always connect non-blocking and expect `EINPROGRESS`, then writability, then `getsockopt(SO_ERROR)`.
- **The ctl file takes only `connect`, `announce`, and `bind`.** There's no half-close and no socket options.
- **UDP has no addressing.** There's no `headers` mode, so a UDP conversation talks only to the address it connected to, and a read doesn't say who sent it. musl's DNS resolver `sendto`s on an unconnected socket and matches replies by their `recvfrom` address, so every hostname lookup from an Alpine program needs it.
- **Conversations are capped machine-wide** at 30 for TCP and 10 for UDP (`newproto` in `ipinit`). A Go HTTP client pool or a small server passes 30 quickly.

A prototype, which passed Linux sockets and readiness through to host sockets, ran Go's `net/http` server and client and a UDP round trip, and Python's asyncio, `http.server` with `urllib`, and `subprocess` with pipes, on arm64 and amd64. Its record of the calls those made is used below.

## Proposal

### Sockets

`socket`, `socketpair`, `connect`, `bind`, `listen`, `accept4`, `sendto`, `recvfrom`, `sendmsg`, `recvmsg`, `getsockname`, `getpeername`, `setsockopt`, `getsockopt`, and `shutdown`, for `AF_INET` and `AF_INET6` with `SOCK_STREAM` and `SOCK_DGRAM`, over `/net` clone files:

- `socket` opens `/net/tcp/clone` or `/net/udp/clone` and keeps the ctl fd with the data fd.
- `connect` writes `connect`, `bind` and `listen` write `announce`, and `accept4` opens the conversation's `listen` file.
- **A non-blocking `connect`** returns `-EINPROGRESS`. devip gains an asynchronous connect: the host socket is connected non-blocking and watched by the host poller (see Readiness), the conversation reports writable when the connection completes or fails, and `getsockopt(SO_ERROR)` reads the result from the conversation's `status`. A blocking `connect` waits for the same thing.
- **`shutdown`** writes a new `shutdown` ctl message (`rd`, `wr`, or `rdwr`), served by `so_shutdown`. asyncio's `write_eof` and HTTP clients half-close, and a peer's half-close is what `EPOLLRDHUP` reports.
- **UDP** gains 9front's `headers` mode: after a `headers` ctl message, each write starts with the destination address and port and each read with the source's, so `sendto` and `recvfrom` work on unconnected sockets. musl's resolver needs it.
- `getsockname` and `getpeername` read `local` and `remote`.
- Socket options that h9 can honour (`SO_REUSEADDR`, `TCP_NODELAY`, `SO_KEEPALIVE`, and `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, and `TCP_KEEPCNT`, which Go sets on every connection) become new ctl messages in devip; the rest are accepted and recorded, so `getsockopt` returns them. `SO_ERROR` is read from the conversation.
- **Conversation caps** grow from 30 TCP and 10 UDP to limits set by the machine (4096 and 1024 by default), allocated as they're used.
- `AF_UNIX` sockets are served by pipes for `socketpair`, and by `/srv`-style posting for named sockets once [devsrv](0008-devsrv.md) is built; until then, `bind` on `AF_UNIX` is `-EAFNOSUPPORT`. (Built since; see Updates.)
- DNS goes through the Linux root's `/etc/resolv.conf`, as Linux's libc does (see Open issues).

The policy's devip hooks apply, so `--net=disable` masks sockets entirely (`socket` is `-EACCES`), and [net-policy](0005-net-policy.md)'s rules apply once it's built.

### Readiness in the kernel

A leaf `h9_poll(fds, n, timeout)` in `src/kern/` asks each fd's channel whether it's readable, writable, or hung up, and sleeps until one is or the timeout passes:

- **qio-backed channels:** `qcanread`, `qfull`, and the queue's closed state. A hook called from qio's existing wakeups wakes pollers on that queue.
- **devip conversations:** the host socket's readiness, from a per-machine host poller thread (`kqueue` on macOS, `epoll` on Linux, `WSAPoll`, or IOCP on Windows) watching the `sfd`s pollers ask about. It wakes the pollers when a socket changes.
- **The console:** the console reader's queue, as for other qio channels.
- **devfs files:** always ready.
- **devmnt and other channels:** reported ready, so a read blocks as it would without `poll`. This is wrong for a 9P-served pipe, but right for files.

`poll`, `ppoll`, and `pselect6` call `h9_poll` directly. A negative fd in a `pollfd` array is ignored, as on Linux; CPython's selectors pass them. **`epoll`** keeps an interest list per epoll fd, level-triggered and edge-triggered, and `epoll_pwait` calls `h9_poll` on it, filtering edges by a per-entry sequence number bumped on each wakeup. Both modes are on the critical path: Go registers every socket with `EPOLLET|EPOLLRDHUP|EPOLLIN|EPOLLOUT`, and asyncio uses level-triggered `EPOLLIN` and `EPOLLOUT` with frequent `EPOLL_CTL_DEL`. **`eventfd2`** is a small device with a counter, readable when non-zero.

### Non-blocking fds

`O_NONBLOCK`, set at open, with `fcntl`, or with `ioctl(FIONBIO)` (which CPython uses), makes `read`, `write`, `accept4`, and `connect` check readiness first and return `-EAGAIN` (or `-EINPROGRESS` for `connect`) instead of blocking. The check and the call aren't atomic: if another reader takes the data in between, the read blocks. For qio channels the check and the read are one step under the queue's lock, a read that takes what's queued and never sleeps, so there's no gap. For sockets it calls the host with `MSG_DONTWAIT`, and a non-blocking `accept4` with nothing pending is `-EAGAIN`.

## Rationale

**Readiness in h9's kernel code, not in a translator.** A translator running as a guest program could only build `poll` from helper processes, one per fd, as linuxemu did. h9 owns the kernel, so it can ask the channels directly.

**Asking host sockets, not adding queues to devip.** A queue in front of each socket would need a reader thread per socket and copy every byte twice. The host already knows when a socket is ready.

**Extending devip rather than going around it.** Async connect, `shutdown`, UDP headers, and socket options could be served by host sockets h9 opens itself, beside devip. But then `/net` wouldn't show them, and the policy's devip hooks would need a second home. 9front's own devip has headers mode and more ctl messages, so these edits move drawterm's toward it.

**Hooks rather than vendor changes.** qio's wakeups get one call to a leaf, and devip's conversations expose their `sfd` through a leaf. Where a hook can't be added without editing the vendored file, the edit is one line, marked `h9:`, as devfs's hooks are.

## Compatibility

- **Vendored tree:** a wakeup hook in `qio.c` and an `sfd` accessor for devip, each a line or two, marked `h9:`. devip's changes are larger: an asynchronous connect, `shutdown`, `headers` for UDP, the socket-option ctl messages, and growable conversation tables, in `devip.c` and each `devip-*.c`, marked `h9:`. They're worth offering upstream.
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

1. Sockets over `/net`, blocking only, with devip's `shutdown`, socket options, and larger conversation tables. A blocking TCP client and server.
2. `h9_poll` for qio channels, `poll`, `ppoll`, `pselect6`, `O_NONBLOCK`.
3. The host poller for devip, sockets in `h9_poll`, and devip's asynchronous connect. UDP `headers`, and DNS through musl's resolver.
4. `epoll` and `eventfd`. curl and `http.server`.
5. DESIGN.md's Linux personality section gains sockets and readiness.

## Open issues

- **`/etc/resolv.conf`.** DNS needs UDP `headers` (see Sockets) and a resolver address. Alpine's minirootfs has none, and the Linux root is read-only by default. Serving one from the host's resolver needs a place to put it: devlinux can't add a file inside the root's `/etc` without shadowing the rest of it, since Plan 9 unions don't merge below the top. A bind of a devlinux file over an existing one works only if the root has the file. Options: write it into an overlay once [overlay](0011-overlay.md) is built, or have fetch.sh add one to the fixture.
- **Readiness for devmnt.** A 9P server that serves a pipe-like file can't report readiness in 9P2000. A `Tread` with a zero count, or a dotl-style extension, might.
- **`AF_NETLINK`**, which `ip` and some libraries probe, is `-EAFNOSUPPORT`. Is anything common blocked by that?
- **`SO_PEERCRED`** for `AF_UNIX`, and passing fds with `SCM_RIGHTS`, once named Unix sockets exist.

## Updates

- 2026-11-07: Choices made in the first implementation:
  - `recvfrom` and `sendto` with addresses go to the host socket through a leaf rather than through a UDP `headers` mode, with the policy's connect check on each `sendto` destination. An unbound, unconnected UDP socket's first `sendto` connects it instead of binding, since the default policy refuses a bind. musl's resolver works with one nameserver; Alpine still has no `/etc/resolv.conf` (see Open issues).
  - Socket options, `shutdown` and the asynchronous connect are devip control messages (`sockopt NAME VALUE`, `shutdown rd|wr|rdwr`, `nbconnect ADDR!PORT`), which 9front programs can use too. Options set before the host socket exists are applied when devip makes it.
  - The host socket stays blocking: an asynchronous connect sets it non-blocking only around `connect`, and `MSG_DONTWAIT` covers the rest, so devip's own reads and writes are unchanged.
  - Every wake bumps one generation and wakes every poller, rather than waking pollers per queue. Edge-triggered epoll reports an fd again only once the generation has moved.
  - A host-socket watcher (a kproc polling the sockets pollers wait on, with a wake pipe; a 10 ms `WSAPoll` loop on Windows) wakes pollers when a socket changes.
  - A Linux pipe read takes everything queued, not one write's worth, as Linux does.
  - Accept waits in `h9_poll` before opening devip's `listen` file, so a signal can interrupt it; devip's backlog stays at 5.
  - The Go `net/http` case and the curl and `http.server` demos are still to come.
- 2026-11-07: The Go `net/http` case runs, with [linux-threads](0049-linux-threads.md). It found that the host-socket watcher never woke: its wake-pipe write and read were wrapped in `USED()`, which drops its argument, so pollers waited for the next unrelated wake. Edge-triggered epoll also stopped waiting for an fd whose other events were still unreported.
- 2026-11-07: DNS. A Linux root without `/etc/resolv.conf` gets one naming the host's DNS servers (Google's public ones where the host names none): devlinux attaches `#λetc`, a directory of files a root may lack, and the machine binds it after the root's `/etc` only when the root has no `resolv.conf`, so the rest of `/etc` stays visible (the Open issue's worry about shadowing is about binding at `/`). The policy allows port 53 to those servers even when link-local, since a cloud VM's resolver is 169.254.169.254, with a caveat in the plan. busybox `nslookup` binds its UDP socket to port 0 before connecting; where the policy refuses that announce, the bind now leaves the socket unbound for its connect.
- 2026-11-08: Named `AF_UNIX` sockets are built on [devsrv](0008-devsrv.md), which had landed, for PostgreSQL's local connections:
  - A socket's fd is a pipe end from `socket` on. `bind` creates an empty file at the path, exclusively (`EADDRINUSE` if it exists), whose device and qid name the socket in `#s` (`lx.DEV.QPATH`); an abstract name is `lxa.` and its bytes in hex, held from the bind by an empty post.
  - `listen` makes a pipe, posts its write end under that name, and puts the read end in the socket's fd, so `poll` and `epoll` see a pending connection as readable.
  - `connect` makes a pipe for the connection, posts one end as `lxc.PID.N`, writes the name down the listener's pipe, and keeps the other end. `accept` reads a name, opens the post and removes it.
  - A connect with no listener is `ECONNREFUSED`, and the last close of a listening socket removes its post. Reads and writes on a socket that isn't connected are `ENOTCONN`, not a write on a closed pipe: busybox `su` logs to `/dev/log` over a datagram socket, and died of `SIGPIPE` until then.
  - The rest stays simple. Posts are per machine, so sockets connect only within one machine. `stat` shows the bound file as a regular file. A datagram socket can't send to a path. `SO_PEERCRED` reports the caller's own ids, and `shutdown` is accepted and does nothing. `SCM_RIGHTS` is still left out.

- 2026-11-08: Found running Redis:
  - A process that exited without closing a socket left it open, so its peer never read EOF (`redis-cli shutdown` hung). The hostpoll kproc, started by the first process to poll a host socket, shared that process's fd table and namespace and never released them; it drops both when it starts.
  - `IPV6_V6ONLY` is passed to the host socket. An `AF_INET` socket's wildcard bind names `0.0.0.0`, so it's an IPv4 host socket, where it was devip's any address, which is dual-stack IPv6 on a host with IPv6. On a host without IPv6, `socket(AF_INET6)` is `EAFNOSUPPORT`, as on Linux without it, where devip listened on IPv4 for `::`. Either way an IPv4 and an IPv6 wildcard listener on one port, Redis's default `bind * -::*`, collided with `EADDRINUSE`.

- 2026-11-08: Found running esbuild, whose `--serve` lists the interfaces' addresses with Go's `net.InterfaceAddrs` and accepts a request only for one of them or `localhost`:
  - `AF_NETLINK` with `NETLINK_ROUTE` answers the dumps that list links (`RTM_GETLINK`) and addresses (`RTM_GETADDR`), which Go's `net.Interfaces` and `net.InterfaceAddrs`, musl's `getifaddrs` and busybox `ip addr` make (`src/linux/netlink.zig`). Any other request gets `EOPNOTSUPP`, and other netlink protocols are `EPROTONOSUPPORT`. This answers the Open issue: Go programs that list interfaces need it. The interfaces are the host's, from `getifaddrs` (`src/kern/hostif-posix.c`), or loopback alone on Windows and the browser, and under `--net=disable`. The socket is a pipe end, as a Unix socket is, and each send's answers are written to a new pipe that replaces it, one message per write, so each read is one datagram.
  - devip's `so_bind` bound the wildcard whatever address an announce named, so a socket bound to `127.0.0.1` listened on every interface and `getsockname` said `0.0.0.0`. It binds the address asked for now (`third_party/drawterm/kern/devip-posix.c`, `devip-win32.c`).

- 2026-11-08: Found running git: `#λetc/resolv.conf` reported length 0, as `/proc` files do, and c-ares (Alpine's curl, so git over https) sizes the file with `lseek` before reading it, took it as empty, and fell back to a nameserver at 127.0.0.1. `wget`, `apk`, and `nslookup` read to EOF, so they resolved. Its stat length is now its text's.

- 2026-11-08: Found running iroh (n0's `dumbpipe`, Rust, quinn-udp): its UDP transport reads with `recvmmsg` and has no fallback, so every receive failed with `ENOSYS`. `recvmmsg` and `sendmmsg` are loops over `recvmsg` and `sendmsg`; after the first message, `recvmmsg` takes only what's already queued, as with `MSG_WAITFORONE`, and its timeout isn't honoured. `UDP_SEGMENT` and `UDP_GRO` are refused with `ENOPROTOOPT` where they were accepted and recorded: control messages aren't carried, so a sender that set a segment size had its batch sent as one oversized datagram. QUIC stacks probe both options and fall back to a datagram per call.

- 2026-11-09: Found running Wine, whose client and wineserver pass fds over a Unix socket:
  - `SCM_RIGHTS` is carried. `sendmsg` with fds posts each in `#s` (`lxf.N`) and records the batch against the receiving pipe end, with the bytes already queued ahead of its message (`h9_linux_pipequeued`, devpipe's queue length). A read on that end stops at a message with fds, and `recvmsg` takes that message's fds, opens them with their modes, and honours `MSG_CMSG_CLOEXEC`; a plain read that takes the message closes its fds, as Linux does. A control buffer too small for the fds is `MSG_CTRUNC`. Batches are per machine, as posts are.
  - A listening socket's bound file `stat`s as `S_IFSOCK`, since it has a post in `#s`, so Wine's check that its server socket is a socket passes. A bound socket that isn't listening still shows as a regular file.
  - Still open: `shutdown` still does nothing, so wineserver logs `sock_check_pollhup()` at start, and goes on.
