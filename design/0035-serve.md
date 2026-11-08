---
id: 35
slug: serve
title: Serving the namespace over 9P
status: draft
created: 2026-11-06
authors: [progrium]
depends: [8, 21]
areas: [cli, kern, sandbox, web]
---

# Proposal: Serving the namespace over 9P

## Abstract

`--serve ADDR` makes h9 a 9P server while its program runs. Each connection gets its own `exportfs` of the machine's namespace, so a client sees what the guest sees, under the same access rules. h9 listens on the host, on a unix socket (`unix!PATH`), on TCP (`tcp!HOST!PORT`), or on a WebSocket (`ws://HOST:PORT/PATH`). A 9front machine, another h9, or anything with a 9P2000 client can mount it, and so can an h9 in a browser tab, using a [websocket-9p](0021-websocket-9p.md) root or `/net/ws`. Accepted connections enter the kernel through websocket-9p's devhstream, as host-made streams do. Before a connection reaches `exportfs`, its first `Tversion` passes through a slot where [dotl](0022-dotl.md) adds its 9P2000.L translator. This proposal leaves the slot empty.

## Background

- **h9 is a client only.** It mounts servers: host trees through devfs, 9P roots from [9p-roots](0013-9p-roots.md), WebSocket roots and `/net/ws` from websocket-9p. It can't share a machine's namespace with anything outside the machine.
- **Inside the machine, serving already works.** `exportfs` is in the root tree, and [devsrv](0008-devsrv.md) notes that it needs nothing more than h9 already serves. A guest can run `aux/listen1 tcp!*!564 exportfs` itself under `--net=enable`. But the listener is then the guest's, on devip, subject to `--net` (`outbound` refuses `announce`). It can't take a unix socket or a WebSocket, and the plan doesn't show it.
- **Two drafts each wanted a server.** websocket-9p listed `h9 --serve wss://…` as its other half. dotl had a `--serve` of its own for Linux clients. Both needed the same listener, the same exportfs-per-connection model, and the same policy, so this proposal is that shared part.
- **devhstream** (websocket-9p) carries a host connection into the kernel as a channel, with a Zig reader thread and leaves that never block a guest thread. It is the device for host-made streams that no guest path names.

## Proposal

### Flags

| Flag | Meaning |
| --- | --- |
| `--serve ADDR` | Repeatable. Listen on `unix!PATH`, `tcp!HOST!PORT`, or `ws://HOST:PORT[/PATH]` while the program runs. Port `0` picks a free port |
| `--serve-root PATH` | The guest path each connection exports. `/` by default |
| `--serve-token @FILE` | WebSocket listeners require this token, as `Authorization: Bearer TOKEN` or `?token=TOKEN` |
| `--serve-origin ORIGIN` | Repeatable. An `Origin` a WebSocket listener accepts, such as `https://app.example`. `*` accepts any |

These are usage errors (exit 2):
- an address in none of the three forms;
- `ws://` without an explicit host, or `wss://`;
- `--serve-root`, `--serve-token`, or `--serve-origin` without a `--serve` they apply to;
- `--serve` on the browser host.

A listen that fails before the program runs, such as an address in use or a socket path that can't be created, exits 125 with the cause (`serve tcp!127.0.0.1!5640: address in use`).

**Unix socket paths.** If `PATH` exists and is a socket that refuses a connection, it's a stale socket from an earlier run, and h9 removes it and listens. If it accepts a connection, the address is in use. If it isn't a socket, h9 doesn't touch it and exits 125 (`serve unix!/tmp/h9.sock: not a socket`). h9 removes the sockets it created when the run ends.

**Port 0.** `tcp!HOST!0` and `ws://HOST:0/PATH` listen on a port the host picks. Once listening, h9 prints the bound address to stderr, `serve: tcp!127.0.0.1!53122`, one line per such listener, before the program starts. Library callers read every listener's bound address from `Machine.serving()`. Listeners with an explicit port print nothing.

### Lifetime

The listeners open after the namespace is built and before the program starts. They close when the program exits, and open connections are hung up. h9 exits with the program's status, as it always does. `--timeout` and notes end the run as they end any run.

**Serving only.** `--serve` with no program is a run that only serves: `h9 --serve unix!/tmp/h9.sock`. It's otherwise a usage error (exit 2), so this changes no existing invocation. The first Proc doesn't exec anything. It sleeps in the kernel until a note arrives, so Ctrl-C, SIGTERM, SIGHUP, and `--timeout` end it as they end any run, with the same grace period for open connections. The console isn't read, so a serve-only run can be started in the background without stopping on terminal input. A serve-only run ended by a note exits 0, as a server its operator stops does, whatever [exit-status](0033-exit-status.md) decides for programs killed by notes: there's no program to have been killed. The plan shows `program: none (serve only)`.

### Each connection

1. **Accept.** A Zig listener thread per address, in `src/serve.zig`, accepts the connection. For `ws://` it first reads the HTTP request (see WebSocket listeners). It then registers the connection with devhstream as a host-made stream: a raw byte stream for unix and TCP, a framed one for WebSocket.
2. **The dialect slot.** h9 reads the client's first message, which must be a `Tversion`. In this proposal it's passed through, and exportfs negotiates as 9P2000 servers do, answering a version it doesn't know with `unknown`. [dotl](0022-dotl.md) fills the slot: `9P2000.L` routes the connection through its server-side translator.
3. **Serve.** The machine's server Proc forks a new Proc with the stream's channel as fds 0 and 1 and execs `/bin/exportfs -r PATH`, with `-R` under `--write=none`, as listen(8) does for a network service. The server Proc is created from the first Proc after the plan's namespace is built and before the program runs, with its own copy of that namespace. So every connection sees the plan's namespace, not changes the program later makes in its own.
4. **End.** When the client hangs up, exportfs reads EOF and exits. When exportfs exits, h9 closes the connection.

A root tree without `/bin/exportfs` makes `--serve` fail before the program runs, exit 125 (`serve: /bin/exportfs not in root`).

Every client acts as the machine's user, which exportfs runs as. The `uname` in its `Tattach` isn't checked.

### WebSocket listeners

`ws://HOST:PORT/PATH` is websocket-9p's wire, from the server's side, in `src/ws.zig`:

- **Requests.** h9 answers an HTTP/1.1 `GET` for `PATH` (`/` by default) with `Upgrade: websocket` and `Sec-WebSocket-Version: 13`. Any other path gets 404, any other method 405, and a request that isn't an upgrade gets 426. h9 serves nothing else over HTTP.
- **Subprotocol.** If the client offers `9p`, h9 selects it. If the client offers none, h9 selects none. A client that offers others but not `9p` gets 400.
- **Origin.** Browsers send `Origin`, and other clients usually don't. A request with no `Origin` is accepted. A request whose `Origin` isn't allowed by `--serve-origin` gets 403. So by default, no web page can open a connection, even to a loopback listener, unless its origin is listed.
- **Token.** With `--serve-token`, a request without the token in its `Authorization` header or its `token` query parameter gets 401. The query form is for browsers, which can't set headers. Query strings end up in proxy and access logs, so clients that can set headers should use the header. The token is compared in constant time.
- **Frames.** Each write exportfs makes is sent as one binary message, which is one 9P message, since exportfs writes whole messages. Received binary payloads go to exportfs's stream whatever their boundaries, as on websocket-9p's client side. A text message closes the connection with 1003. websocket-9p's 16 MiB limits apply, and so do pings and closes.

No TLS. `wss://` is served by a reverse proxy, such as Caddy or nginx, that terminates TLS in front of a `ws://` listener on loopback, and forwards the `Upgrade` and `Origin` headers. The `Origin` check and the token work behind it unchanged.

### `Machine.Options`

```zig
pub const Listen = union(enum) {
    unix: []const u8,
    tcp: []const u8,
    /// host:port and path, from a ws:// URL.
    ws: []const u8,
};
serve: []const Listen = &.{},
serve_root: []const u8 = "/",
/// Required on WebSocket listeners when set.
serve_token: ?[]const u8 = null,
/// Origins WebSocket listeners accept; "*" for any.
serve_origins: []const []const u8 = &.{},
```

An empty `argv` with a non-empty `serve` is a serve-only run. `Machine.serving()` returns each listener's bound address, in the order given, once the listeners are open, so a caller that asked for port 0 can find the port.

The per-connection path takes any devhstream stream, not a socket. Listeners are one source of streams; the test-only source in Implementation is another, and a page's `MessagePort` could be a third ([browser-host](0012-browser-host.md)'s updates).

### The plan

`--print` lists each listener under a `serve` heading, with the token elided, and a caveat for each listener with no authentication:

```text
serve:
  unix!/tmp/h9.sock                     exportfs -r /
  ws://127.0.0.1:8080/9p                exportfs -r /   (token, origins: https://app.example)
caveats:
  - served without authentication on unix!/tmp/h9.sock
```

### Limits

**Keepalive.** WebSocket listeners send a ping after 30 seconds without receiving a frame, and close a connection that sends nothing within another 30 seconds, as websocket-9p's client does. Browsers answer pings but can't send them, so this is what keeps a browser client's connection open through proxies.

A machine serves at most 32 connections at once, across all its listeners. Beyond that, a new connection is closed when it's accepted, or answered with 503 on a WebSocket listener.

**Processes.** Each connection's exportfs is a guest process, and exportfs forks more to answer requests that block. The server Proc and its descendants are counted under `--pids` separately from the program's processes, each against the full `--pids` value. So clients can't use up the program's processes and make its `rfork` fail, and a program that forks to its cap doesn't refuse clients. A run can have up to twice `--pids` live processes, and the plan's `limits` line says so when `--serve` is given (`pids=32 (+32 serving)`). An `rfork` past the serving cap fails in exportfs, which answers that request with an error. Memory isn't split: exportfs's memory counts under `--memory` with the program's, so serving can't take more memory than the run allows.

## Rationale

**Serving in one proposal, with WebSocket in it.** websocket-9p's client and dotl's .L each wanted a server, and the parts they'd both need are the listener, the exportfs model, the lifetime, and the policy, not anything about framing or dialect. Putting those in one place means one security story: who may connect, what they see, and how the plan shows it. WebSocket is the listener with the most policy (origins, tokens, HTTP), and leaving it out would decide the policy for unix and TCP only, then revisit it. It depends on websocket-9p for `ws.zig` and devhstream, both of which are written first there.

**Listening on the host, not through devip.** A guest can already serve with `aux/listen1` on `/net/tcp`. But a unix socket or a WebSocket has to be the host's, and a listener the plan opens belongs to the plan, as a 9P root's connection does. That's also why `--net` doesn't govern it: `--net=outbound` refuses the guest's `announce`, not the operator's `--serve`. The operator names each address, and the plan prints it.

**exportfs, not a server in Zig.** exportfs is 9front's namespace server, already correct for every device the machine has, and it serves through the guest's namespace, so devfs's access rules, `--read-deny`, and the write policy hold without a second implementation. Serving from Zig straight off kernel channels would save a process and a copy per message, but it would be a second 9P server to keep correct.

**A namespace snapshot, not the program's live namespace.** The program can `rfork n` and change its namespace at any time. A server that followed one process's namespace would race with it, and would end when that process does. The plan's namespace is what `--print` shows, so it's what a client gets.

**devhstream for every connection.** Accepted unix and TCP connections could go through devlfd's `lfdchan`, as 9p-roots' unix roots do. devhstream already carries a WebSocket, has the reader-thread design that keeps a guest thread out of host calls, and works on every host. websocket-9p's open issues expected it to carry other host-made connections, and this is the first.

**Refusing `Origin` by default.** A loopback listener is reachable from every web page the host's browser opens, and WebSocket isn't subject to CORS. Without an origin check, any page could mount the machine. Clients that aren't browsers don't send `Origin`, so the default costs them nothing.

**A token, not 9P authentication.** exportfs answers `Tauth` with "authentication not required", and 9P auth would need factotum on both ends. A bearer token in the upgrade is what WebSocket services use, and it works from a browser through the query. Unix sockets rely on file permissions. TCP has neither and says so in the plan (see "Raw TCP stays unauthenticated").

**Separate process counts for serving.** Clients are outside the program's control, and exportfs forks per blocking request, so a shared `--pids` would let a busy client make the program's `rfork` fail, which reads as a bug in the program. A share reserved for the program would need a second number to pick. Counting each side against `--pids` keeps one flag and isolates the two. Memory stays shared, since splitting it would halve what a program that doesn't serve much could use.

**Serving with no program, not a subcommand.** h9 has no subcommands, so `h9 ls` runs `ls`, and an `h9 serve` would be the first. No program is a usage error today, so giving it a meaning under `--serve` breaks nothing. Exiting 0 when a note ends it matches how a server stopped by its operator exits, and is what service managers expect from a clean stop.

**Raw TCP stays unauthenticated.** 9P authentication on the server side would put a key in the guest, for factotum, against [root-auth](root-auth.md)'s rule that the guest never holds one, or have h9 run `p9any` on the host in front of exportfs, a design of its own. A unix socket has file permissions, and a WebSocket listener has a token, so a listener that needs authentication uses one of those. TCP is for trusted networks and loopback, and the plan's caveat names every TCP listener.

**One root for all listeners.** Every client is the machine's user, since the kernel has one user. Mapping clients to users, by token or by a unix socket peer's credentials, would need a machine with several, which nothing proposes. Pairing a root with each listener (`--serve unix!/a.sock=/usr/a`) would only give clients different subtrees of the same namespace, under the same user and the same policy. Clients that need different views or policies need different machines, which separate runs give, each with its own `--serve-root`. The `=PATH` form can be added later without breaking anything if a use appears.

**A caveat, not a flag, for unauthenticated TCP.** There's no default address, so an operator who types `tcp!0.0.0.0!5640` has already chosen to listen on the network. A flag such as `--serve-insecure` would be added to the same command lines by habit, and say nothing the address doesn't. The plan's caveat names every unauthenticated listener instead.

**No HTTP server.** h9 answers WebSocket upgrades on one path and nothing else, so it's not a web server, and there's no static file serving to secure.

**No TLS server.** Zig's standard library has a TLS client, which websocket-9p uses, and no TLS server. Serving `wss://` natively would mean a server-side TLS stack, certificate and key handling, and reloading, for what a reverse proxy already does well. A run is short-lived, so a proxy in front of it is the usual deployment anyway.

## Compatibility

- **CLI:** new `--serve`, `--serve-root`, `--serve-token`, and `--serve-origin`. Exit 2 for misuse, 125 for a listen that fails. No program, an error today, is a serve-only run when `--serve` is given, and still an error without it.
- **`Machine.Options`:** new `serve`, `serve_root`, `serve_token`, and `serve_origins`, and `Machine.serving()`.
- **Limits:** `--pids` counts serving processes separately, so a run with `--serve` can have up to twice as many live processes. Without `--serve`, unchanged.
- **Sandbox defaults:** unchanged. Nothing listens without `--serve`.
- **The root tree:** unchanged. `/bin/exportfs` is already in it.
- **`third_party/`:** unchanged.
- **Browser host:** `--serve` is an error.

## Security

- **What a client reaches.** The plan's namespace from `--serve-root` down, as the machine's user, through exportfs. devfs's access rules apply: `--read-deny` paths are hidden, read-only paths refuse writes, and `--write=none` adds exportfs's `-R`. A client reaches nothing the guest couldn't. But it does reach everything the guest could, including `/mnt/term`, `/srv`, and `/net`. `--serve-root` narrows it.
- **Who can connect.** Unix sockets are created mode 0600. TCP and WebSocket listeners take whatever host the operator names, including non-loopback addresses. Those without a token, which is every TCP listener, are listed in the plan as served without authentication. There's no default address, so h9 never listens anywhere unasked.
- **Browsers.** WebSocket listeners refuse requests carrying an `Origin` that `--serve-origin` doesn't list, so a page the user visits can't reach a loopback listener. DNS rebinding gets a page's own origin, which is refused the same way.
- **`/net` through a client.** A client that walks to `/net` in the export reaches devip as the guest does, under the guest's `--net` policy, since `/net` is served through the guest's namespace. Under `--net=disable`, `#I` is masked and there's nothing there.
- **Hostile clients** send anything. exportfs rejects malformed 9P. Frames and buffers are bounded by websocket-9p's limits, connections by the cap of 32, and processes and memory by `--pids` and `--memory`.
- **Credentials.** `--serve-token @FILE` keeps the token out of the process listing, and `--print` and `--trace` elide it. A token sent as `?token=` is in the request URL, which a reverse proxy may log. h9 doesn't log request URLs, but an operator using the query form should keep the proxy's logs private or rotate the token.
- **Who connected.** `--trace` logs each accepted connection with its listener and peer: the address for TCP and WebSocket, and the peer's uid and pid for a unix socket (`SO_PEERCRED` on Linux, `LOCAL_PEERCRED` and `LOCAL_PEERPID` on macOS). Nothing is decided by them.

## Done when

Integration cases tagged `[serve]`. The client is a second h9, which mounts with a 9P root, a websocket-9p root, or `/net/ws`. HTTP-level cases use a small Zig client from `ws.zig`.

- `test "an h9 root over --serve unix! lists the served tree [serve]"`
- `test "an h9 root over --serve tcp! lists the served tree [serve]"`
- `test "an h9 ws:// root over --serve ws:// lists the served tree [serve]"`
- `test "a guest mounts a --serve ws:// listener through /net/ws [serve]"`
- `test "--serve-root exports only that subtree [serve]"`
- `test "--serve under --write=none refuses writes [serve]"`
- `test "--read-deny paths aren't visible through --serve [serve]"`
- `test "clients see the plan's namespace, not the program's later binds [serve]"`
- `test "listeners close and clients see hangups when the program exits [serve]"`
- `test "a ws:// listener refuses an unlisted Origin with 403 [serve]"`
- `test "a ws:// listener with --serve-token refuses a request without it [serve]"`
- `test "a ws:// listener accepts the token in the query [serve]"`
- `test "the 33rd connection is refused [serve]"`
- `test "clients exporting at the --pids cap don't stop the program's rfork [serve]"`
- `test "--serve with no program serves until a hangup and exits 0 [serve]"`
- `test "--serve tcp!127.0.0.1!0 prints the bound address [serve]"`
- `test "a stale unix socket is replaced and removed at exit [serve]"`
- `test "a unix socket path that isn't a socket exits 125 [serve]"`
- `test "a ws:// listener pings an idle client and closes one that stops answering [serve]"`
- `test "an address in use exits 125 [serve]"`
- `test "--print lists listeners and elides the token [serve]"`

Demos:
- `h9 --serve unix!/tmp/h9.sock`, then in another shell `h9 --root unix!/tmp/h9.sock ls /mnt/term`.
- `h9 --serve ws://127.0.0.1:8080/9p --serve-origin http://localhost:8000`, then the browser host's demo page at `?root=ws://127.0.0.1:8080/9p`, once [browser-host](0012-browser-host.md) is built.

## Implementation

1. The server Proc and the per-connection fork and exec of `exportfs`, with a test-only stream source.
2. `src/serve.zig` with unix and TCP listeners (stale sockets, port 0, `Machine.serving()`), devhstream's raw streams, `--serve` and `--serve-root`, `Machine.Options`, serve-only runs, and the limits, with the separate `--pids` count.
3. `ws.zig`'s server side (written for websocket-9p's test relay) wired to WebSocket listeners, with the HTTP checks, `--serve-origin` and `--serve-token`.
4. The plan's `serve` heading, caveats, elision, and `pids` line in `src/policy.zig`, the `--write=none` `-R`, and `--trace`'s connection lines.
5. The dialect slot, empty, ready for [dotl](0022-dotl.md).
6. README: the flags and the demos. DESIGN.md: a Serving section, the CLI flag table, and `Machine.Options`. Set `status: implemented`.

## Open issues

None. Follow-ups recorded elsewhere: 9P authentication for served TCP in [root-auth](root-auth.md)'s open issues, and serving to the page over a `MessagePort` in [browser-host](0012-browser-host.md)'s updates.
