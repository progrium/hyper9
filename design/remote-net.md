---
slug: remote-net
title: A host's network for the web host
status: draft
created: 2026-11-10
authors: [progrium]
depends: [12, 21, 35, 50]
areas: [cli, kern, sandbox, web]
---

# Proposal: A host's network for the web host

## Abstract

`--net-via URL` gives a machine on the [browser host](0012-browser-host.md) a real network: another h9's `/net`, served over a WebSocket with [serve](0035-serve.md)'s `--serve-net`. On the web host, devip's socket layer (`devip-wasm.c` and `hostsock-wasm.c`, stubs today) is built over that machine's conversations, so `#I` works there. Plan 9 programs dial through it as natively, and so does the [Linux personality](0050-linux-net.md)'s socket layer, with poll, non-blocking sockets, `MSG_PEEK`, and UDP. The web machine's `--net` and `--net-allow` apply to every connect and announce before it leaves the tab, and the serving machine's own policy applies again on the host. `createMachine({ netVia })` is the page's form.

## Background

- **The web host has no sockets.** `#I` is always masked there, and `--net=outbound` and `enable` bind `#ℏ` alone at `/net`, so `/net/ws` is the guest's whole network ([browser-host](0012-browser-host.md)'s updates). A page can open WebSockets and nothing else.
- **A native h9 can already serve its `/net`.** `h9 --serve ws://127.0.0.1:5640/ --serve-root /net --serve-net` exports the machine's devip, `cs` included, to any 9P client, under its own `--net` and `--net-allow`, with `--serve-origin` and `--serve-token` checked at the WebSocket's handshake.
- **Plan 9 programs can use it today, by hand.** In the browser guest, `wsmount -b ws://127.0.0.1:5640/ /net` mounts the host's `tcp`, `udp`, and `cs` before `/net/ws`, and a `dial(2)`, or an rc function that writes `connect` to `/net/tcp/N/ctl`, goes through the host. This was checked in Chromium against the demo page, with a host h9 on the emulator. The mount isn't a `#` attach, so the mask on `#I` doesn't stop it.
- **Linux programs can't.** The Linux layer's socket calls open `#I/tcp/clone` and `#I/udp/clone` by device name (`src/linux/sys.zig`), not through `/net`, and it knows a socket fd only by its channel being devip's (`convOf`, and `sockof` in `src/kern/linuxnet.c`). Readiness, `MSG_PEEK`, `MSG_DONTWAIT`, and `SO_ERROR` come from the conversation's host socket (`h9so_*` in `hostsock.h`) and the watcher that wakes pollers. A channel from a 9P mount has none of these: devmnt can't say whether a read would block.
- **The hand mount skips the tab's policy.** Its traffic is reads and writes on a 9P mount, so the web machine's `--net-allow` never sees a connect. Only the serving machine's policy applies.

## Proposal

### The flag

| Flag | Meaning |
| --- | --- |
| `--net-via URL` | On the web host, devip's sockets are the conversations of the `/net` served at URL, a `ws://` or `wss://` 9P server |

URL is a 9P server whose root is a devip tree, with `tcp`, `udp`, and `cs`, such as `h9 --serve ws://HOST:PORT/ --serve-root /net --serve-net`. A server that exports a whole namespace can be named with a path to its `/net` as the attach spec, as `--root-spec` does (open issue).

These are usage errors (exit 2): `--net-via` natively, `--net-via` with `--net=disable`, and a URL that isn't `ws://` or `wss://`. A connection that fails at boot exits 125 with the cause, as a WebSocket root does (`net-via ws://127.0.0.1:5640/: connection failed`).

With `--net-via`, the web host's policy stops masking `#I` under `outbound` and `enable`, and binds `#I` at `/net` with `#ℏ` after it, as natively. Without it, nothing changes.

`Machine.Options` gets `net_via: ?[]const u8 = null`. `createMachine({ netVia: 'ws://127.0.0.1:5640/' })` passes the flag. The demo page takes `?net=URL`.

### Remote sockets

`devip-wasm.c`'s `so_*` calls and `hostsock-wasm.c`'s `h9so_*` calls are built over a table of remote conversations. Each entry, a "socket" by devip's reckoning, holds the remote conversation's `ctl` and `data` channels, a receive buffer, a send queue, and an error. devip.c is unchanged: it already calls the `so_*` layer for every protocol operation, and the Linux layer's `h9so_*` calls already take devip's socket fd.

- **socket.** `so_socket` opens the remote `tcp/clone` or `udp/clone`, reads the conversation number, and opens its `data`. UDP conversations are put in `headers` mode, so each read and write carries the peer's address, as devip's UDP does.
- **connect.** `so_connect` writes `connect ADDR!PORT` to the remote `ctl` and returns when it's answered. `h9so_connect_nb` starts the same write in a kernel coroutine and returns 1, in progress. Its result is the socket's error, read by `SO_ERROR`, and it wakes pollers.
- **announce, listen, and accept.** `announce` goes to the remote `ctl`. A listen opens the remote `listen` file, which blocks on the host until a call comes, in a coroutine, so `accept` and readiness work as for any socket.
- **receive.** One reader coroutine per socket reads the remote `data` into a buffer of 64 KiB and parks while it's full. `h9so_recvfrom` takes from the buffer, so `MSG_PEEK` and `MSG_DONTWAIT` are answered from it. A read of 0 is the end of the stream, ready as `POLLIN|POLLRDHUP`, and an error is `POLLERR` and `SO_ERROR`.
- **send.** A send writes to the remote `data`. A non-blocking send copies into the send queue, up to `SO_SNDBUF` (64 KiB by default), and a writer coroutine drains it. `POLLOUT` is ready while the queue has room.
- **readiness.** `h9so_ready` answers from the buffer, the queue, and the error, and the reader and writer coroutines call `h9_pollwake`, as the host socket watcher does natively. `h9so_watch` and `h9so_unwatch` have nothing to watch.
- **addresses.** `so_getsockname` and the peer's address come from the remote `local` and `remote` files.
- **options.** `nodelay` and `keepalive` are written to the remote `ctl`, where devip takes them, and the rest are recorded and ignored, since the host owns the real socket.
- **close.** `so_close` closes the channels, which hangs up the host's conversation, and ends the coroutines.
- **cs.** devip's `cs` on the web host forwards each query to the remote `cs`. `/net/dns` isn't served.
- **interfaces.** `h9so_ifaddrs` returns none, so the Linux layer's netlink lists loopback, as for a machine without `#I`.

The remote tree is reached through devhstream, as a WebSocket root is. It's attached once at boot, in the kernel, and never appears in the guest's namespace.

### Policy

The web machine's `--net` and `--net-allow` are checked by devip's own calls to `h9_net_check`, as natively, before anything is written to the remote `ctl`: `outbound` refuses `announce`, and `--net-allow` checks a connect's address. A name in a connect is resolved by the remote `cs` first, and the addresses it returns are what's checked, so the resolved-address checks that `/net/ws` can't make on the web host work here. The serving machine's `--net` and `--net-allow` apply again to the same operations on the host, so a connection must pass both.

The plan shows `net: via ws://127.0.0.1:5640/`, with the token elided, under the `--net` line.

### On the serving side

Nothing changes. A host that serves its network to a page runs:

```sh
host$ h9 --serve ws://127.0.0.1:5640/ --serve-root /net --serve-net \
     --serve-origin https://app.example --serve-token @token --net=outbound
```

## Rationale

**In the socket layer, not the Linux layer.** The Linux layer could open `/net` through the namespace instead of `#I`, so a hand mount would reach it. But its readiness, peek, and non-blocking calls all need a buffer and a coroutine per socket, since devmnt can't say whether a read would block, and its fd checks would have to accept any channel. Doing it under devip keeps one socket layer for Plan 9 and Linux programs, keeps devip's policy checks where they are, and leaves the Linux layer unchanged.

**9P, not a WebSocket-to-TCP proxy.** A websockify-style relay, with a WebSocket per connection, would need a server h9 doesn't have, can't carry UDP or listens without a protocol of its own, and would put the policy outside h9. Serving `/net` over 9P reuses `--serve`, its handshake checks, its limits, and the serving machine's policy, and the same server works for a native client's hand mount.

**The hand mount stays.** `wsmount -b URL /net` keeps working, and the manual describes it, for Plan 9 programs and for servers other than h9. `--net-via` is for Linux programs and for the tab's own policy.

**Web host only, at first.** A native machine already has host sockets. Borrowing another machine's network natively (an egress host, say) is the same layer over devhstream, but it would put a second socket layer behind `hostsock-posix.c` and `hostsock-win32.c`. It's an open issue.

## Compatibility

New: `--net-via`, `Machine.Options.net_via`, `createMachine`'s `netVia`, and the demo page's `?net=`. Without them nothing changes: `#I` stays masked on the web host, and `/net/ws` is still its network. The serving side has no changes. `third_party/` is unchanged; `devip-wasm.c` and `hostsock-wasm.c` are ours.

## Security

The tab's guest can reach whatever the serving machine's `--net` and `--net-allow` allow, and no more, filtered first by the tab's own policy. A served `/net` is an open proxy for anyone who can reach the listener, which is why `--serve-net` is off by default and the plan lists it as a caveat. A page can only use it if its origin passes `--serve-origin`, and with `--serve-origin '*'`, only with the token. The token travels in the URL's query, since a page can't set headers, so it appears in the host's and any proxy's logs. The demo page keeps `?net=` out of the history it shares, and the manual says to use a token on anything but loopback.

## Done when

- `test "--net-via outside the web host is a usage error [remote-net]"`
- `test "--net-via with --net=disable is a usage error [remote-net]"`
- `test "a web machine dials TCP through --net-via [remote-net, browser-host]"`
- `test "cs on the web host answers from the --net-via server [remote-net, browser-host]"`
- `test "--net-allow refuses a --net-via connect before it reaches the host [remote-net, browser-host]"`
- `test "outbound refuses announce on --net-via [remote-net, browser-host]"`
- `test "a Linux program connects, sends, and receives through --net-via [remote-net, linux-net]"`
- `test "poll, MSG_PEEK, and a non-blocking connect on a --net-via socket [remote-net, linux-net]"`
- `test "UDP sendto and recvfrom through --net-via [remote-net, linux-net]"`
- `test "the plan shows net via the URL [remote-net]"`
- The demo page with `?net=ws://127.0.0.1:5640/` and `?linux&net=ws://127.0.0.1:5640/`, against a host h9 serving its `/net`, fetches a page with a Plan 9 dial and with busybox `wget`, in `tests/web/browser.mjs`.

## Implementation

1. The flag, `Machine.Options.net_via`, the usage errors, and the plan line, in `src/cli.zig`, `src/machine.zig`, and `src/policy.zig`, with `#I` bound under `--net-via` on the web host.
2. The boot-time attach of the remote tree through devhstream, beside the WebSocket root's.
3. Remote sockets in `devip-wasm.c` and `hostsock-wasm.c`: the table, `socket`, `connect`, `announce`, `listen`, `close`, and the reader coroutine. The Plan 9 cases.
4. The send queue, readiness, `SO_ERROR`, `MSG_PEEK`, `MSG_DONTWAIT`, and UDP's headers mode. The Linux cases.
5. `cs` forwarding.
6. `createMachine`'s `netVia`, the demo page's `?net=`, and the browser test.
7. MANUAL.md and SPEC.md. Set `status: implemented`.

## Open issues

- **Serving's process cap.** Each connection's exportfs gets 8 processes, and each socket's reader holds one in a blocking read, as does each pending connect or listen. So one connection carries at most about 7 busy sockets. The client could open a connection per few sockets, up to serve's 32, or serve could lift the cap for `--serve-net` connections. The first needs no change on the serving side.
- **A whole namespace as the server.** Whether `--net-via` takes a path within the server's tree (`ws://host/9p#/net`, say), so a host can serve one namespace for a root and the network.
- **Natively.** Whether a native machine should take `--net-via`, as an egress host through another h9.
- **Latency.** Every send is a 9P round trip to the host. Small writes could be coalesced in the send queue, as Nagle's algorithm does, unless `nodelay` is set.
