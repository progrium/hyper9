---
id: 21
slug: websocket-9p
title: 9P over WebSocket
status: draft
created: 2026-11-05
authors: [progrium]
depends: [5, 8, 13]
areas: [cli, kern, sandbox, web]
---

# Proposal: 9P over WebSocket

Nov 5, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

A 9P server can be reached over a WebSocket: `--root ws://host/path` or `wss://host/path`, and `mount 'wss://…' /n/x` in namespace files. h9 makes the connection on the host, before the program starts, and devmnt mounts it as it mounts a [9P root](9p-roots.md)'s connection. The WebSocket is carried into the kernel by a new host-stream device, `src/kern/devhstream.c`, built on the pattern devhcons uses for the console: leaf calls into Zig, a host reader thread, and the guest sleeping in the kernel. Natively, Zig does the TCP, TLS and WebSocket framing. On the [browser host](0012-browser-host.md), the page's own `WebSocket` does, which makes this the browser host's only way to reach a file server over the network.

The guest can open WebSockets too. The same device is bound at `/net/ws`, laid out like devip's `/net/tcp`, so a guest writes `connect wss://…` to a conversation's `ctl` and mounts its `data` with the ordinary `mount` command. [net-policy](0005-net-policy.md)'s `--net` and `--net-allow` decide which URLs it may connect to. On the browser host, `/net/ws` is the guest's only network.

## Background

### Why WebSocket

- **The browser host has no sockets.** [browser-host](0012-browser-host.md) masks `#I`, since a Worker can't open TCP connections. A WebSocket is the only bidirectional network transport a page has, so without it a browser h9 can only run what's in its root archive or what the embedder lends it through WASI.
- **Natively, it's 9P that crosses the web's infrastructure.** A WebSocket goes through HTTP proxies, load balancers and TLS terminators that plain TCP on port 564 doesn't, and `wss` gives the connection TLS and the HTTP layer's authentication (a bearer token, a cookie, a signed URL) without a factotum. [9p-roots](9p-roots.md) lists "the 9P root's connection isn't encrypted" as a caveat and leaves authentication open. For a root reached over `wss`, both have an answer.
- **One URL for both hosts.** A server that speaks 9P over WebSocket can be the root of an h9 in a terminal and of an h9 in a browser tab, from the same `wss://` URL.

There's no standard for 9P over WebSocket, but existing servers and bridges agree on the essentials: binary messages, with 9P's own size-prefixed messages as the payload.

### h9 today

- **9P roots** are proposed in [9p-roots](9p-roots.md): `--root tcp!host!port` dials through devip and `--root unix!path` wraps a host socket with devlfd's `lfdchan`. Either way devmnt mounts the connection at `/` before any other bind, and the root's connection isn't subject to `--net`, since h9 makes it, not the guest.
- **devmnt reads a byte stream.** `mntrpcread` in drawterm's `kern/devmnt.c` reads the size, type and tag, then reads until it has the whole message, through the channel's `bread`. It doesn't need a message per read, so any channel that delivers the server's bytes in order can carry 9P.
- **devhcons** (`src/kern/devhcons.c`) is a kernel device whose reads and writes are leaf calls into Zig (DESIGN.md, seam rule 3). A Zig reader thread (`src/consin.zig`) does the host reads, and a guest read sleeps on a Rendez until there's input, so a note or a teardown interrupts it with `Eintr`.
- **Guest mounts** come with [devsrv](0008-devsrv.md), which serves the `mount`, `unmount` and `fauth` syscalls. `mount` takes any open fd that speaks 9P, and the `mount` command opens any path, not only `/srv` entries.
- **Guest networking** is devip (`#I`) at `/net`, governed by [net-policy](0005-net-policy.md): `--net=disable` masks `#I`, `outbound` refuses `announce`, and `--net-allow` patterns are checked on every `connect` and at `/net/cs`, through the Zig leaves `h9_net_check`, `h9_net_lookup` and `h9_net_resolved`. The browser host masks `#I`, so a guest there has no network at all.
- **No WebSocket client** exists in the 9front userland. webfs speaks HTTP but doesn't do the upgrade, and nothing else in the pinned root tree does.
- **No WebSocket code** exists in h9 or drawterm. Zig's standard library has a TLS client (`std.crypto.tls.Client`) and the system's certificate bundle (`std.crypto.Certificate.Bundle`), but no WebSocket client.

## Proposal

### URLs

| Form | Meaning |
| --- | --- |
| `ws://host[:port][/path][?query]` | A WebSocket over TCP. Port 80 by default |
| `wss://host[:port][/path][?query]` | A WebSocket over TLS, verified against the host's certificate bundle. Port 443 by default |

They're accepted wherever [9p-roots](9p-roots.md) accepts a dial string: `--root`, `$H9ROOT`, and the source of a `mount` line in a namespace file. A string with either prefix is a URL, so it can't be confused with a host path or a `tcp!` dial string.

### The wire

- **Handshake.** An HTTP/1.1 `GET` with `Upgrade: websocket`, `Sec-WebSocket-Version: 13`, a random `Sec-WebSocket-Key`, and `Sec-WebSocket-Protocol: 9p`. The server must answer `101`, with the right `Sec-WebSocket-Accept`. It may select `9p` or no subprotocol. Any other subprotocol, or any other status, fails the connection. Redirects aren't followed. No extensions are offered, so there's no `permessage-deflate`.
- **Sending.** Each 9P message devmnt writes is sent as one binary message, masked as RFC 6455 requires of clients. devmnt writes a whole message per write, so this is one frame per message.
- **Receiving.** Binary payloads are appended to the stream devmnt reads, whatever their boundaries, so a server that splits a 9P message across WebSocket messages, or packs several into one, still works. A text message is a protocol error.
- **Control frames.** A ping is answered with a pong. A close is answered with a close, and the stream ends, so devmnt fails the mount's later RPCs as for any hangup ("i/o on hungup channel").
- **Limits.** A message larger than 16 MiB, or a stream that buffers more than 16 MiB unread, fails the connection. devmnt's `msize` (8192 plus header by default) is far below that, so only a broken or hostile server reaches it.

### Headers

| Flag | Meaning |
| --- | --- |
| `--root-header 'NAME: VALUE'` | Repeatable. An HTTP header sent with a WebSocket root's handshake, such as `Authorization: Bearer …` |
| `--root-header @FILE` | Reads headers from a host file, one per line, so a token isn't in the process listing |

A header that would change the handshake itself (`Host`, `Upgrade`, `Connection` or any `Sec-WebSocket-*`) is a usage error, exit 2. `--root-header` with a root that isn't a URL is a usage error too. `mount` lines in namespace files send no extra headers; a token for one goes in its URL's query.

### The host-stream device

`src/kern/devhstream.c` turns a host connection into a channel devmnt can mount. It's devhcons's design applied to a connection instead of a console:

- **Leaves** in `src/kern.zig`: `h9_hstream_read(id, buf, n)`, `h9_hstream_ready(id)`, `h9_hstream_write(id, buf, n)` and `h9_hstream_close(id)`. They return a status and never raise kernel errors; the C side raises them.
- **Reads** never block in a host call. A reader thread per stream, `src/hstream.zig`, reads frames and queues payload bytes, and calls `h9_hstream_wake(id)` when it queues some or the stream ends. A guest read sleeps on the stream's Rendez until the queue has bytes, so notes, `--timeout` and teardown interrupt it as they do a devmnt RPC on any channel.
- **Writes** frame and send on the caller's thread, under a lock per stream, since the payload is small and a send that blocks holds back only devmnt's writer.
- **Host-made streams aren't reachable by the guest.** The namespace builder gets a host-made stream's channel from a kernel call, `hstreamchan(id)`, not through an attach spec, so no path names it. The guest-facing tree (`/net/ws`, below) lists only the conversations the guest made, and its attach takes no spec. A host-made stream is reachable only as the channel under its mount.
- **Lifetime.** A stream belongs to its machine. When the machine ends, its streams are closed with a WebSocket close (1001, going away) and their reader threads stopped.

The Zig side is in two parts:

- **`src/ws.zig`:** the handshake, frame encoding and decoding, and masking, as pure functions over a `std.Io.Reader` and `std.Io.Writer`, with no sockets. It's tested in `zig build test` against recorded handshakes and frames.
- **`src/hstream.zig`:** the stream table and reader threads. On native hosts it connects with `std.Io`'s TCP, wraps the connection in `std.crypto.tls.Client` for `wss`, with the system certificate bundle loaded once per process, then runs `ws.zig`'s handshake. On the web host it calls into `h9-web.js` instead (below).

### `Machine.Options`

[9p-roots](9p-roots.md)'s `Root` gains a case, and the options gain the headers:

```zig
pub const Root = union(enum) {
    dir: []const u8,
    tcp: []const u8,
    unix: []const u8,
    /// A 9P server over a WebSocket: a ws:// or wss:// URL.
    ws: []const u8,
};
root: ?Root = null,
root_spec: []const u8 = "",
root_user: ?[]const u8 = null,
/// Extra HTTP headers for a `ws` root's handshake, as `Name: value`.
root_headers: []const []const u8 = &.{},
```

### Connecting and mounting

As for a TCP root, in the machine's first Proc, before any other bind and before the device mask is set:

1. **Connect.** `hstream.open(url, headers)` connects, does TLS for `wss`, and does the handshake, returning a stream id.
2. **Post** `#ℏ<id>`'s channel to the machine's `/srv` board as `root`, as for a TCP root, so `mount '#s/root' …` in a namespace file attaches it again.
3. **Mount** `#s/root` at `/` with `MREPL` and the spec from `--root-spec`. devmnt sends `Tversion` and `Tattach` over it, with `--root-user` or the machine's user as `uname`.

Then the plan's binds run over it, as over any root.

**Failures** before the program runs exit 125 with the cause:

- `root wss://fs.example/9p: connection refused`
- `root wss://fs.example/9p: certificate: unknown authority`
- `root wss://fs.example/9p: server answered 401 Unauthorized`
- `root wss://fs.example/9p: server didn't select the 9p subprotocol`
- and 9p-roots' `Tversion` and `Tattach` failures.

### Namespace files

A `mount` line whose source is a `ws://` or `wss://` URL connects a new stream the same way and mounts it, during `--ns` replay:

```text
mount -c 'wss://fs.example/9p?token=…' /n/fs
mount 'ws://127.0.0.1:8080/9p' /n/scratch work
```

The flags and spec mean what they mean for any mount. A failure stops the replay and exits 125, as other replay errors do. Replay runs before the device mask, so a namespace file can mount a WebSocket server under `--net=disable`.

### WebSockets for the guest: `/net/ws`

Attached with no spec, devhstream serves a tree laid out like devip's protocol directories. The namespace builder binds it with `bind -a '#ℏ' /net`, beside `#I`, so it appears as `/net/ws`:

| File | Use |
| --- | --- |
| `/net/ws/clone` | Opening it makes a new conversation and returns its `ctl`, open. Reading gives the conversation's number |
| `/net/ws/N/ctl` | Takes text messages (below). Closing the last fd on `ctl` and `data` closes the conversation |
| `/net/ws/N/data` | The stream. Each write is sent as one binary message, and reads return received payload bytes in order, whatever the message boundaries |
| `/net/ws/N/remote` | The URL, as given to `connect` |
| `/net/ws/N/status` | `Idle`, `Connecting`, `Established 9p`, or `Closed 1000 reason`, with the selected subprotocol and the close code |

`ctl` messages:

- **`header Name: value`** adds a handshake header, before `connect`. The same headers are refused as for `--root-header`. On the web host it's an error.
- **`connect url [subprotocol …]`** connects, does TLS for `wss`, and does the handshake, offering the listed subprotocols, or none. The write returns when the server has answered `101`, or fails with the cause, as the root's errors read. A note interrupts it.
- **`hangup`** sends a close (1000) and ends the stream.

A conversation is a guest-made stream: the same table, reader thread, framing and limits as a host-made one, owned by the machine. A machine has at most 32 conversations, like devip's 30 TCP conversations, and they're counted against nothing else. Each machine's tree lists only its own, found through the caller's `Hproc.mach` as devsrv and devproc do.

**Mounting** is then the ordinary `mount`, which [devsrv](0008-devsrv.md) serves:

```rc
{ n=`{read}
  echo connect wss://fs.example/9p 9p >/net/ws/$n/ctl
  mount -c /net/ws/$n/data /n/fs } <>/net/ws/clone
```

Once `data` is mounted, the mount holds the conversation open, so the clone fd can close. The root tree has no `wsmount` command, and nothing here adds one to it. The snippet goes in README, and a user can keep it as an rc function. A conversation's `data` can also be posted to `/srv`, so other processes in the machine can mount it, as with any channel.

**The device isn't 9P-specific.** Any guest program can use `/net/ws` as a WebSocket client for binary messages. Text messages from the server are a protocol error in this proposal (Open issues).

### The policy and the plan

Everything [9p-roots](9p-roots.md) says about a 9P root applies to a WebSocket root, and to a WebSocket mount:

- Writes go to the server, which decides what's writable. `--write=none` with a WebSocket root, or with a namespace file that mounts one, is a usage error, exit 2. [overlay](overlay.md) covers a WebSocket root as any other.
- `--net` doesn't apply to the connections h9 makes. The guest gets nothing through them: their channels aren't in `/net/ws`.

Guest conversations follow [net-policy](0005-net-policy.md), with the URL's host and port treated as a TCP dial:

| `--net` | `/net/ws` | `connect` |
| --- | --- | --- |
| `disable` | Not bound, and `#ℏ` masked | - |
| `outbound` | Bound | Allowed, or checked against `--net-allow` |
| `enable` | Bound | Allowed, or checked against `--net-allow` |

The checks are net-policy's, made by `hstream.zig` before it touches the network:

1. **The name.** If the URL's host is a name, it must be allowed as `cs` would allow it, by `h9_net_lookup`'s rule, for `tcp` and the URL's port. A name no pattern covers isn't resolved, so the guest can't put data into DNS queries.
2. **The addresses.** h9 resolves the name, records the result as `cs` does with `h9_net_resolved`, and checks each address with `h9_net_check(H9_NETCONNECT, …)` before connecting to it. So `tcp!*.example.com!443` allows `wss://fs.example.com/9p`, the built-in link-local refusal applies when there are no patterns, and a literal address in the URL is checked like a literal in a dial string.
3. **Refusals** fail the `connect` write with "permission denied", as a refused devip `connect` does.

The 16 MiB limits on messages and buffered bytes apply per conversation, and buffered bytes come from the machine's page allocator, counted against `--memory`, so a guest that never reads can't hold more than its memory limit.

`--print` shows the URL with its query and userinfo replaced by `…`, and the headers by name only:

```text
$ h9 --print --root 'wss://fs.example/9p?token=abc' --root-header @~/.fs-token ls
...
namespace:
  mount '#s/root' /                                       9p  # wss://fs.example/9p?…  (Authorization: …)
  bind '#c' /dev
  ...
  bind -a '#I' /net
  bind -a '#ℏ' /net                                       # WebSockets, under --net
  ...
caveats:
  - writes to the 9P root go to its server, which decides what can be written
  ...
```

For a `ws://` URL, the plan has 9p-roots' caveat that the connection isn't encrypted. For `wss://` it doesn't. Under `--net=disable`, `#ℏ` is on the `devmask:` line beside `#I`. `--trace` shows a guest's `connect` with its URL's query elided, as `--print` does.

### On the browser host

On the [browser host](0012-browser-host.md), `hstream.zig`'s native connect is replaced by imports from `h9-web.js`:

- **`h9_ws_open(url, protocols)`** makes a `WebSocket` with `binaryType = "arraybuffer"` and the given subprotocols, and is `Suspending`: it parks until `open` or `error`.
- **`h9_ws_send(id, buf, n)`** sends a copy of the bytes. It doesn't park.
- **`h9_ws_recv(id, buf, n)`** is `Suspending`. It takes from a queue the page's `message` handler fills, and parks while the queue is empty.
- **`h9_ws_close(id)`.**

The browser does the handshake, TLS, masking and pings, so `ws.zig` isn't used there. There's no reader thread either: a guest read calls `h9_ws_recv` from its own coroutine, which parks, and a note wakes it as it wakes any park. devhstream is the same file on both hosts.

The page can't set headers on a `WebSocket`, so `root_headers` is an error on the web host. Authentication is a cookie for the server's origin, or a token in the URL's query. The browser sends the page's `Origin`, which the server should check. A page served over `https` can only open `wss://` URLs.

`createMachine({ root: "wss://fs.example/9p", rootSpec, … })` takes the same `Root` as native embedders, and namespace files mount URLs as above.

**`/net/ws` on the web host** is the same tree, over the same imports. It's the guest's only network there, since `#I` stays masked:

- `--net=outbound` and `enable` bind `/net/ws` and nothing else at `/net`. They're no longer listed as unenforced on the web host, since what they allow, outbound WebSockets, is enforced. `announce` has nothing to refuse.
- `--net-allow` checks names and literal addresses in the URL. The browser resolves names itself and doesn't say what to, so the address checks after resolution, and the link-local refusal for names, can't be made. The plan lists that as a caveat on the web host. The browser's own rules apply on top: mixed content, and the page's Content-Security-Policy `connect-src`.
- `header` in `ctl` is an error, as `root_headers` is. This is the browser host's first network-backed root, and it fits beside the WASI backings [browser-host](0012-browser-host.md) lists: the root archive for the base system, and a WebSocket server for a project's files.

## Rationale

**A host-stream device, not devip plus devtls plus a WebSocket device in the kernel.** That would keep the transport in the guest's kind of code, but it's three layers of C for one connection, it needs a WebSocket implementation written against drawterm's kernel, and none of it works on the browser host, where there's no devip and the browser insists on doing WebSocket itself. The host-stream device is one small device with one leaf interface, and each host implements the leaves the way it can: Zig natively, the browser's `WebSocket` on the web.

**devhcons's pattern.** It's already how h9 gives the kernel a host stream that must not block a guest thread in a host call. Reusing it means interruption, teardown and the seam rules work the way they already do for the console.

**Not devlfd and a socketpair.** A relay thread copying between a WebSocket and one end of a socketpair, with the other end in `lfdchan`, would reuse drawterm code, but it adds a copy and a socket per connection, and devlfd's handle I/O doesn't suit sockets on Windows (see 9p-roots' Open issues). Leaves into Zig work the same on every host.

**Not a bridge outside h9.** `websockify` in front of a `tcp!` root works natively once 9p-roots is built. It doesn't help the browser host, which can't dial TCP at all, and it leaves the TCP leg unencrypted and unauthenticated. Native support is what lets one `wss://` URL serve both hosts.

**URLs, not a dial string.** A WebSocket endpoint is a URL with a path and a query, which a `!`-separated dial string can't hold without inventing an escaping. The `ws://` and `wss://` prefixes can't be confused with paths or dial strings, so both forms coexist.

**A message per 9P message when sending, a stream when receiving.** Sending whole messages is what servers that read a message per frame expect, and devmnt makes it free. Accepting any framing on receive costs nothing, since devmnt already reassembles, and works with servers that treat the WebSocket as a byte pipe. Being strict on what's sent and tolerant on what's received is how h9 interoperates without a standard.

**The `9p` subprotocol, optional.** Offering it lets a server that serves more than one protocol on one endpoint pick 9P. Accepting a server that selects none works with the bridges and servers that ignore subprotocols. Refusing a different one avoids speaking 9P to something that agreed to speak something else.

**Headers natively, cookies and query on the web.** Bearer tokens are how most HTTP services authenticate, and `@FILE` keeps one out of `ps`. The browser forbids custom headers on a WebSocket, so the web host can't offer them, and says so rather than dropping them.

**A kernel device for the guest, not a userspace client.** No 9front program speaks WebSocket, and writing one means TLS, HTTP and framing in guest code, plus a pipe or `/srv` dance to hand the stream to `mount`. On the browser host it couldn't exist at all: a guest has no sockets, so a WebSocket can only come from the page. Exposing devhstream, which h9 needs anyway for roots, gives the guest the same transport on both hosts for the cost of a directory tree and a `ctl` parser.

**Under `/net`, shaped like devip.** `clone`, `ctl`, `data`, `remote` and `status` are what Plan 9 programs and people already expect of a network protocol directory, so `/net/ws` reads like `/net/tcp`, and the policy that governs `/net` governs it. A dial string (`ws!host!port`) for libc's `dial` was rejected for the same reason URLs were: a path and query don't fit, and `cs` would have to learn a URL syntax.

**A write per message.** devmnt writes a whole 9P message per write, so this sends one frame per 9P message, and lets other binary protocols keep their own message boundaries when sending. Reads stay a stream, as devmnt and most programs want.

**Checking at connect, reusing net-policy's leaves.** A WebSocket is a TCP connection by the time anything leaves the host, so `tcp!host!port` patterns mean the same thing for both, and a user writes one allowlist. Checking the name before resolving keeps net-policy's guarantee that the guest can't make the host resolve names the allowlist doesn't cover.

**No reconnect.** devmnt has no way to re-establish fids on a new connection, so a reconnected stream would be a new server as far as every open file is concerned. A hangup fails operations, as it does on 9front and for 9p-roots.

**Depending on 9p-roots, devsrv and net-policy.** The `Root` union, `--root-spec`, `--root-user`, the root's post to `#s/root`, the plan's `mount` line and the write policy are 9p-roots'. This proposal adds a transport to them. Guest mounts need devsrv's `mount` and `fauth` syscalls, and guest connects need net-policy's modes and leaves. The web half also needs [browser-host](0012-browser-host.md), but the native half doesn't, so it's not in `depends`: the web backing is the last implementation step, and lands once browser-host is built.

## Compatibility

- **`--root` and `$H9ROOT`** accept `ws://` and `wss://` URLs. Every form 9p-roots accepts means what it did.
- **`--root-header`** is new.
- **`Machine.Options`:** `Root` gains `ws`, and `root_headers` is new.
- **Namespace files:** `mount` accepts a URL as its source. Lines that parsed before mean what they did.
- **`--print`** shows WebSocket roots and mounts as above.
- **Exit codes:** connection, TLS and handshake failures are 125; header misuse and `--write=none` with a WebSocket root are 2.
- **Sandbox defaults:** the default profile's `--net=outbound` now also binds `/net/ws`, so a guest can open outbound WebSockets wherever it can open TCP connections. The tight profile's `--net=disable` masks it. A run whose guest makes no connection, and has no URL root, makes no WebSocket connection.
- **The namespace:** `/net` gains `ws` whenever `#I` is bound, and on the web host whenever `--net` isn't `disable`.
- **Build:** no new dependencies. TLS and the certificate bundle are Zig's standard library.
- **Vendored tree:** unchanged. devhstream is project code in `src/kern/`, and devmnt is used as it is.
- **Browser host:** `createMachine` accepts a URL root. Its JS API otherwise doesn't change. `--net=outbound` and `enable` become enforced there, as `/net/ws` only, which changes [browser-host](0012-browser-host.md)'s statement that they're unenforced.

## Security

- **What the guest newly reaches, through host-made connections:** the files the server serves, at `/` or at the mount point. Not the server's network, the WebSocket itself, or any other stream: their channels aren't in `/net/ws` and no attach spec names them.
- **What the guest newly reaches, through `/net/ws`:** any WebSocket endpoint the network policy allows, the same set of hosts and ports it could already reach with `/net/tcp` natively. A guest that can dial TCP could already speak WebSocket by hand, so natively this adds convenience, not reach. On the web host it's new reach: the guest had no network before, and with `--net=outbound` it can now open WebSockets to anywhere the page's browser rules allow. Embedders that don't want that pass `--net=disable`, and the tight profile does.
- **Requests the host makes for the guest.** A guest `connect` makes h9 resolve a name, open TCP and, for `wss`, TLS, all with the host's resolver, network and certificate bundle. Names are checked before they're resolved, and addresses before they're connected to, so the guest can't use the host to reach what `--net-allow` refuses, or to send data in DNS queries for names it doesn't cover. Redirects aren't followed and proxies aren't used, so a server can't send h9 somewhere the check didn't see.
- **What the server sees:** every file operation on the mount, `--root-user` or the machine's user as `uname`, the attach spec, the URL and headers, and, on the web host, the page's `Origin` and its cookies for the server's origin. A run trusts a WebSocket root as it trusts any root: it runs the server's binaries, inside the same sandbox.
- **Transport.** `wss` connections are verified against the host's certificate bundle, or the browser's, with no way to turn verification off in this proposal. `ws` connections are plain, and the plan says so.
- **Credentials.** Headers and URL queries can carry tokens. `--print` and `--trace` elide queries, userinfo and header values. `--root-header @FILE` keeps a token out of the process listing. A token in a namespace file's URL is as visible as the file.
- **A hostile server** can send anything. Frames are bounded, the buffered stream is bounded, and devmnt rejects malformed 9P, so the worst it can do is fail the mount, or answer as slowly as it likes, which notes and `--timeout` cut short.
- **Host-made connections bypass `--net`,** as 9p-roots' do. They're named in the plan, made before the program runs, and fixed for the run. The guest's own connections never bypass it.
- **Resources.** A machine has at most 32 conversations, buffered bytes count against `--memory`, and a `connect` blocks only its caller, interrupted by notes and `--timeout`.
- **Isolation between machines:** each machine's streams are its own. A machine's `/net/ws` lists only its conversations, host-made streams are in no tree, and only the namespace builder of the machine that opened one mounts it.

## Done when

Integration cases tagged `[websocket-9p]`. The server is 9p-roots' second h9, running `exportfs` behind `aux/listen1`, with `tests/wsrelay.zig` in front of it: a small host program, built from `src/ws.zig`'s server side, that accepts WebSocket connections and relays each to the TCP server. Options make it split and coalesce messages, select no subprotocol, demand a header, or answer the handshake with an error.

- `test "a ws:// root runs /bin/ls [websocket-9p]"`
- `test "rc pipelines and exec run from a ws:// root [websocket-9p]"`
- `test "a ws:// root works when the server splits and coalesces 9P messages [websocket-9p]"`
- `test "a ws:// root works with a server that selects no subprotocol [websocket-9p]"`
- `test "--root-header is sent, and @FILE reads headers from a file [websocket-9p]"`
- `test "a handshake answered with 401 exits 125 with the status [websocket-9p]"`
- `test "an unreachable ws:// root exits 125 [websocket-9p]"`
- `test "a server close makes guest file operations fail [websocket-9p]"`
- `test "a note interrupts a read waiting on a ws:// root [websocket-9p]"`
- `test "a namespace file mounts a ws:// URL [websocket-9p]"`
- `test "a host-made stream isn't reachable through /net/ws or an attach spec [websocket-9p]"`
- `test "the guest connects /net/ws and mounts its data [websocket-9p]"`: the rc snippet above, then `ls /n/fs`.
- `test "a /net/ws conversation reports its URL and status [websocket-9p]"`
- `test "a guest WebSocket mount can be posted to /srv and mounted again [websocket-9p]"`
- `test "header in ctl is sent with the handshake [websocket-9p]"`
- `test "--net=disable leaves /net/ws unbound and #ℏ masked [websocket-9p]"`
- `test "--net-allow refuses a /net/ws connect to a host it doesn't cover [websocket-9p]"`
- `test "--net-allow refuses a name before it's resolved [websocket-9p]"`
- `test "a /net/ws connect to a link-local address is refused without patterns [websocket-9p]"`
- `test "a note interrupts a /net/ws connect [websocket-9p]"`
- `test "a machine can't open more than 32 conversations [websocket-9p]"`
- `test "--print elides a ws:// root's query and header values [websocket-9p]"`
- `test "--write=none with a ws:// root is a usage error [websocket-9p]"`

Unit tests in `src/ws.zig`: the handshake's key and accept, masking, every payload length encoding, fragmented messages, control frames between fragments, and the size limits.

`wss://` is covered by `std.crypto.tls.Client`'s own tests and by one case that runs only when `H9_TEST_WSS_URL` names a reachable server:

- `test "a wss:// root runs /bin/ls [websocket-9p]"`

On the browser host, under Node, with `ws://` cases through Node's built-in `WebSocket`:

- `test "a ws:// root runs /bin/ls on the web host [websocket-9p, browser-host]"`
- `test "root_headers is an error on the web host [websocket-9p, browser-host]"`
- `test "the guest mounts a /net/ws conversation on the web host [websocket-9p, browser-host]"`
- `test "--net=outbound binds only /net/ws on the web host [websocket-9p, browser-host]"`

Demo: `h9 --root ws://localhost:8080/9p ls /` lists the served tree, with the server and relay started as above. From inside a guest, the rc snippet under `/net/ws` with `ws://localhost:8080/9p` mounts the same tree at `/n/fs`. On the web host, the demo page takes a `?root=wss://…` parameter and runs rc on that root.

## Implementation

1. `src/ws.zig`: the client handshake and framing, the server side `tests/wsrelay.zig` needs, and the unit tests.
2. `src/kern/devhstream.c`'s host-made streams: its entry in `src/kern/devtab.c`, `hstreamchan`, the leaves in `src/kern.zig`, and `src/hstream.zig` with native TCP.
3. `ws` roots: `Root.ws`, `root_headers`, `--root` and `--root-header` in `src/cli.zig` and `src/main.zig`, the connect and mount in `src/machine.zig`, the errors, and the `ws://` cases.
4. `wss`: TLS in `src/hstream.zig` with the system bundle, and the opt-in case.
5. Namespace files: URL sources for `mount` in `src/newns.zig` and the replay.
6. The plan: the `mount '#s/root'` line for URLs, the elision, the caveats and the `--write=none` conflict in `src/policy.zig`.
7. `/net/ws`: devhstream's guest tree, `clone`, `ctl`, `data`, `remote` and `status`, per-machine conversations, the `bind -a '#ℏ' /net` and the mask under `--net=disable` in `src/policy.zig`, and net-policy's checks in `src/hstream.zig`. Then the guest cases, and the rc snippet in README.
8. Once [browser-host](0012-browser-host.md) is built: the `h9_ws_*` imports in `h9-web.js`, `hstream.zig`'s web branch, `createMachine`'s URL root, `/net/ws` as the web host's network, and the web cases.
9. README's `--root` notes, `--root-header` and `/net/ws`. DESIGN.md: the root filesystem paragraph, the kernel's "Added by us" table (devhstream), the boot sequence, the capability table's `net.*` rows, the CLI flag table and `Machine.Options`. Set `status: implemented`.

## Open issues

- **Serving 9P over WebSocket.** The other half: `h9 --serve wss://…` or `ws://127.0.0.1:PORT`, giving each connection a fresh `exportfs` of the machine's namespace, would let a browser h9 mount a native h9's host files, or a project directory, with nothing else installed. It needs an HTTP listener on the host, a policy for who may connect, and a decision about what's exported. It's a proposal of its own once the client exists.
- **Text messages.** `/net/ws` handles binary messages only, which is all 9P needs. A guest program talking to a JSON service would want text, perhaps with a `ctl` message (`text` or `binary`) that sets how writes are sent and makes text from the server readable rather than an error.
- **A `wsmount` command.** The rc snippet works, but a command would be nicer. The root tree is 9front's, so it would live in a script h9 ships beside the root, or upstream in 9front, once `/net/ws` exists.
- **TCP for the guest on the web host.** `/net/ws` gives guests WebSockets in the browser, not `/net/tcp`. A relay that tunnels TCP over a WebSocket, as websockify does in reverse, could give them that, at the cost of a server someone has to run.
- **The subprotocol name.** `9p` is offered here. If the servers and bridges people already run (Wanix, Go and JavaScript 9P libraries) settle on another name, such as `9p2000`, h9 should offer that as well, before this is accepted.
- **Idle connections.** Proxies and load balancers close idle WebSockets, often after 60 seconds. h9 could send a ping after some idle time natively. Browsers don't let pages send pings, so on the web host it would be a 9P-level keepalive, or nothing.
- **Proxies.** Native connects go direct. Honouring `HTTPS_PROXY` with `CONNECT` would make `wss` roots work from behind corporate proxies, which is half the point of using WebSocket.
- **Custom trust.** A `--root-ca FILE` for servers with private certificates, which this proposal leaves out so verification can't be weakened by accident.
- **Other transports on devhstream.** The same device could carry 9p-roots' unix-socket roots on Windows, which devlfd can't, and later other host-made connections.
