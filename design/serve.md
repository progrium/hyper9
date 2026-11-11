---
issue: 35
slug: serve
title: Serving the namespace over 9P
status: implemented
created: 2026-11-06
authors: [progrium]
depends: [devsrv, websocket-9p, builtin-root]
areas: [cli, kern, sandbox, web]
branch: [main]
---

# Proposal: Serving the namespace over 9P

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

`--serve ADDR` makes h9 a 9P server while its program runs. Each connection gets its own `exportfs` of the machine's namespace, so a client sees what the guest sees, under the same access rules, except `/net`, which is left out unless `--serve-net` is given. h9 listens on the host, on a unix socket (`unix!PATH`), on TCP (`tcp!HOST!PORT`), or on a WebSocket (`ws://HOST:PORT/PATH`). A 9front machine, another h9, or anything with a 9P2000 client can mount it, and so can an h9 in a browser tab, using a [websocket-9p](websocket-9p.md) root or `/net/ws`. Accepted connections enter the kernel through websocket-9p's devhstream, as host-made streams do. Before a connection reaches `exportfs`, its first `Tversion` passes through a slot where [dotl](dotl.md) adds its 9P2000.L translator. This proposal leaves the slot empty.

## Background

- **h9 is a client only.** It mounts servers: host trees through devfs, 9P roots from [9p-roots](9p-roots.md), WebSocket roots and `/net/ws` from websocket-9p. It can't share a machine's namespace with anything outside the machine.
- **Inside the machine, serving already works.** `exportfs` is in the root tree, and [devsrv](devsrv.md) notes that it needs nothing more than h9 already serves. A guest can run `aux/listen1 tcp!*!564 exportfs` itself under `--net=enable`. But the listener is then the guest's, on devip, subject to `--net` (`outbound` refuses `announce`). It can't take a unix socket or a WebSocket, and the plan doesn't show it.
- **Two drafts each wanted a server.** websocket-9p listed `h9 --serve wss://…` as its other half. dotl had a `--serve` of its own for Linux clients. Both needed the same listener, the same exportfs-per-connection model, and the same policy, so this proposal is that shared part.
- **devhstream** (websocket-9p) carries a host connection into the kernel as a channel, with a Zig reader thread and leaves that never block a guest thread. It is the device for host-made streams that no guest path names.

## Proposal

### Flags

| Flag | Meaning |
| --- | --- |
| `--serve ADDR` | Repeatable. Listen on `unix!PATH`, `tcp!HOST!PORT`, or `ws://HOST:PORT[/PATH]` while the program runs. Port `0` picks a free port |
| `--serve-root PATH` | The guest path each connection exports. `/` by default |
| `--serve-token @FILE` | WebSocket listeners require this token, as `Authorization: Bearer TOKEN` or `?token=TOKEN` |
| `--serve-origin ORIGIN` | Repeatable. An `Origin` a WebSocket listener accepts, such as `https://app.example`. `*` accepts any, and needs `--serve-token` |
| `--serve-net` | Export `/net` too. Without it, clients don't see `/net` |

These are usage errors (exit 2):
- an address in none of the three forms;
- `ws://` without an explicit host, or `wss://`;
- `--serve-root`, `--serve-token`, `--serve-origin`, or `--serve-net` without a `--serve` they apply to;
- `--serve-origin '*'` without `--serve-token`;
- `--serve` on the browser host.

A listen that fails before the program runs, such as an address in use or a socket path that can't be created, exits 125 with the cause (`serve tcp!127.0.0.1!5640: address in use`).

**Unix socket paths.** h9 first takes an exclusive `flock` on `PATH.lock`, created mode 0600, and holds it for the run, so two runs starting at once can't both decide a socket is stale. If the lock is held, the address is in use. If `PATH` exists and is a socket that refuses a connection, it's a stale socket from an earlier run, and h9 removes it and listens. If it accepts a connection, the address is in use. If it isn't a socket, h9 doesn't touch it and exits 125 (`serve unix!/tmp/h9.sock: not a socket`). h9 removes the sockets and lock files it created when the run ends.

**Port 0.** `tcp!HOST!0` and `ws://HOST:0/PATH` listen on a port the host picks. Once listening, h9 prints the bound address to stderr, `serve: tcp!127.0.0.1!53122`, one line per such listener, before the program starts. Library callers read every listener's bound address from `Machine.serving()`. Listeners with an explicit port print nothing.

**`$serve` in the guest.** The program's environment has `serve`, an rc list of every listener's bound address in the order given, port 0 resolved (`serve=(unix!/tmp/h9.sock tcp!127.0.0.1!53122)`). So a program can print where it's served, or hand the address to a client it starts. The list is fixed for the run. Without `--serve`, `serve` isn't set.

### Lifetime

The listeners open after the namespace is built and before the program starts. They close when the program exits, and open connections are hung up. h9 exits with the program's status, as it always does. `--timeout` and notes end the run as they end any run.

**Serving only.** `--serve` with no program is a run that only serves: `h9 --serve unix!/tmp/h9.sock`. It's otherwise a usage error (exit 2), so this changes no existing invocation. The first Proc doesn't exec anything. It sleeps in the kernel until a note arrives, so Ctrl-C, SIGTERM, SIGHUP, and `--timeout` end it as they end any run, with the same grace period for open connections. The console isn't read, so a serve-only run can be started in the background without stopping on terminal input. A serve-only run ended by a note exits 0, as a server its operator stops does, whatever [exit-status](exit-status.md) decides for programs killed by notes: there's no program to have been killed. The plan shows `program: none (serve only)`.

### Each connection

1. **Accept.** A Zig listener thread per address, in `src/serve.zig`, accepts the connection. For `ws://` it first reads the HTTP request (see WebSocket listeners). It then registers the connection with devhstream as a host-made stream: a raw byte stream for unix and TCP, a framed one for WebSocket.
2. **The dialect slot.** h9 reads the client's first message, which must be a `Tversion`. In this proposal it's passed through, and exportfs negotiates as 9P2000 servers do, answering a version it doesn't know with `unknown`. [dotl](dotl.md) fills the slot: `9P2000.L` routes the connection through its server-side translator.
3. **Serve.** The machine's server Proc forks a new Proc with the stream's channel as fds 0 and 1 and execs `exportfs -r PATH`, with `-R` under `--write=none`, as listen(8) does for a network service. The server Proc is created from the first Proc after the plan's namespace is built and before the program runs, with its own copy of that namespace, its own note group (`RFNOTEG`), and, without `--serve-net`, `/net` unmounted. So every connection sees the plan's namespace, not changes the program later makes in its own, and notes posted to the program's group, such as an interrupt from the console, don't reach exportfs.
4. **End.** When the client hangs up, exportfs reads EOF and exits. When exportfs exits, h9 closes the connection.

**Which exportfs.** The server Proc runs `/bin/exportfs` from the root when there is one, and otherwise the built-in root's, `#Hroot/$cputype/bin/exportfs` ([builtin-root](builtin-root.md)'s box has it). So `--serve` works over any root, including a Linux tree with no 9front binaries, which [dotl](dotl.md)'s Linux clients and a VM served from the machine both need. The plan's `serve` heading says which one runs.

**Where the namespace comes from.** The server Proc takes its namespace from a source, and this proposal has one: the plan's namespace, copied once. Exporting a live namespace, or one task's, would be a second source feeding the same per-connection path (see Open issues).

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

The per-connection path takes any devhstream stream, not a socket. Listeners are one source of streams; the test-only source in Implementation is another, and a page's `MessagePort` could be a third ([browser-host](browser-host.md)'s updates).

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

**Per connection.** Each connection's exportfs and the processes it forks can have at most 8 live processes, counted within the serving count below. exportfs forks one per request that blocks, so past 8, the next blocking request on that connection fails with an error, and other connections are unaffected. So one client can't take every serving process from the others.

**Processes.** Each connection's exportfs is a guest process, and exportfs forks more to answer requests that block. The server Proc and its descendants are counted under `--pids` separately from the program's processes, each against the full `--pids` value. So clients can't use up the program's processes and make its `rfork` fail, and a program that forks to its cap doesn't refuse clients. A run can have up to twice `--pids` live processes, and the plan's `limits` line says so when `--serve` is given (`pids=32 (+32 serving)`). An `rfork` past the serving cap fails in exportfs, which answers that request with an error. 
**Memory isn't split.** exportfs's memory counts under `--memory` with the program's, so serving can't take more memory than the run allows, but it can take memory the program would have used. A client that makes exportfs hold large reads, or many connections each at their process cap, can make the program's allocations fail. The serving count and the cap of 32 connections bound how many exportfs processes can hold memory at once. An operator who serves untrusted clients should give the run a `--memory` with room for them. A separate serving cap is an open issue.

## Rationale

**Serving in one proposal, with WebSocket in it.** websocket-9p's client and dotl's .L each wanted a server, and the parts they'd both need are the listener, the exportfs model, the lifetime, and the policy, not anything about framing or dialect. Putting those in one place means one security story: who may connect, what they see, and how the plan shows it. WebSocket is the listener with the most policy (origins, tokens, HTTP), and leaving it out would decide the policy for unix and TCP only, then revisit it. It depends on websocket-9p for `ws.zig` and devhstream, both of which are written first there.

**Listening on the host, not through devip.** A guest can already serve with `aux/listen1` on `/net/tcp`. But a unix socket or a WebSocket has to be the host's, and a listener the plan opens belongs to the plan, as a 9P root's connection does. That's also why `--net` doesn't govern it: `--net=outbound` refuses the guest's `announce`, not the operator's `--serve`. The operator names each address, and the plan prints it.

**exportfs, not a server in Zig.** exportfs is 9front's namespace server, already correct for every device the machine has, and it serves through the guest's namespace, so devfs's access rules, `--read-deny`, and the write policy hold without a second implementation. Serving from Zig straight off kernel channels would save a process and a copy per message, but it would be a second 9P server to keep correct.

**A namespace snapshot, not the program's live namespace.** The program can `rfork n` and change its namespace at any time. A server that followed one process's namespace would race with it, and would end when that process does. The plan's namespace is what `--print` shows, so it's what a client gets.

**devhstream for every connection.** Accepted unix and TCP connections could go through devlfd's `lfdchan`, as 9p-roots' unix roots do. devhstream already carries a WebSocket, has the reader-thread design that keeps a guest thread out of host calls, and works on every host. websocket-9p's open issues expected it to carry other host-made connections, and this is the first.

**Refusing `Origin` by default.** A loopback listener is reachable from every web page the host's browser opens, and WebSocket isn't subject to CORS. Without an origin check, any page could mount the machine. Clients that aren't browsers don't send `Origin`, so the default costs them nothing.

**A token, not 9P authentication.** exportfs answers `Tauth` with "authentication not required", and 9P auth would need factotum on both ends. A bearer token in the upgrade is what WebSocket services use, and it works from a browser through the query. Unix sockets rely on file permissions. TCP has neither and says so in the plan (see "Raw TCP stays unauthenticated").

**Separate process counts for serving.** Clients are outside the program's control, and exportfs forks per blocking request, so a shared `--pids` would let a busy client make the program's `rfork` fail, which reads as a bug in the program. A share reserved for the program would need a second number to pick. Counting each side against `--pids` keeps one flag and isolates the two. Memory stays shared, since splitting it would halve what a program that doesn't serve much could use.

**`/net` left out by default.** Through `/net`, a client can dial anything the guest's `--net` policy allows, from the host's address. A TCP listener has no authentication, so under `--net=enable` it would be an open relay for anyone who can reach it, which the plan's caveat about authentication doesn't make clear. Most clients want files, not the network, so `/net` is left out unless `--serve-net` asks for it, and the plan then shows a caveat for it. `/srv` stays: it holds the machine's posted servers, which are files a client may want, and it's named in Security.

**`*` origins need a token.** Without a token, `--serve-origin '*'` lets every page in every browser on the host mount a loopback listener, which is what the origin check exists to stop. With a token, `*` is reasonable, since a page then needs the token too.

**A cap per connection.** The serving count keeps clients from starving the program, but not from starving each other: one client with many blocking reads could take all of it. 8 covers a client with a few blocking reads (a console, an event file, a pipe) outstanding at once, and the serving count still bounds the total across connections.

**exportfs from the built-in root.** Requiring `/bin/exportfs` would make serving depend on the root being 9front. A Linux root is exactly where Linux clients, through dotl, want to mount the machine. The built-in box is always there and is the same exportfs.

**Its own note group.** The server Proc is forked from the first Proc, so without `RFNOTEG` it would share the program's note group, and an interrupt meant for the program would kill every client's exportfs. Clients are hung up only when the run ends.

**`$serve`, not a device.** The program needs the bound addresses, mainly for port 0, and they don't change during the run. An environment variable is how rc and every language read such a thing, and it needs no new device. Live state, such as connected clients, is in `--trace`.

**Serving with no program, not a subcommand.** h9 has no subcommands, so `h9 ls` runs `ls`, and an `h9 serve` would be the first. No program is a usage error today, so giving it a meaning under `--serve` breaks nothing. Exiting 0 when a note ends it matches how a server stopped by its operator exits, and is what service managers expect from a clean stop.

**Raw TCP stays unauthenticated.** 9P authentication on the server side would put a key in the guest, for factotum, against [root-auth](root-auth.md)'s rule that the guest never holds one, or have h9 run `p9any` on the host in front of exportfs, a design of its own. A unix socket has file permissions, and a WebSocket listener has a token, so a listener that needs authentication uses one of those. TCP is for trusted networks and loopback, and the plan's caveat names every TCP listener.

**One root for all listeners.** Every client is the machine's user, since the kernel has one user. Mapping clients to users, by token or by a unix socket peer's credentials, would need a machine with several, which nothing proposes. Pairing a root with each listener (`--serve unix!/a.sock=/usr/a`) would only give clients different subtrees of the same namespace, under the same user and the same policy. Clients that need different views or policies need different machines, which separate runs give, each with its own `--serve-root`. The `=PATH` form can be added later without breaking anything if a use appears.

**A caveat, not a flag, for unauthenticated TCP.** There's no default address, so an operator who types `tcp!0.0.0.0!5640` has already chosen to listen on the network. A flag such as `--serve-insecure` would be added to the same command lines by habit, and say nothing the address doesn't. The plan's caveat names every unauthenticated listener instead.

**No HTTP server.** h9 answers WebSocket upgrades on one path and nothing else, so it's not a web server, and there's no static file serving to secure.

**No TLS server.** Zig's standard library has a TLS client, which websocket-9p uses, and no TLS server. Serving `wss://` natively would mean a server-side TLS stack, certificate and key handling, and reloading, for what a reverse proxy already does well. A run is short-lived, so a proxy in front of it is the usual deployment anyway.

## Compatibility

- **CLI:** new `--serve`, `--serve-root`, `--serve-token`, `--serve-origin`, and `--serve-net`. Exit 2 for misuse, 125 for a listen that fails. No program, an error today, is a serve-only run when `--serve` is given, and still an error without it.
- **`Machine.Options`:** new `serve`, `serve_root`, `serve_token`, and `serve_origins`, and `Machine.serving()`.
- **Limits:** `--pids` counts serving processes separately, so a run with `--serve` can have up to twice as many live processes, with at most 8 per connection. Without `--serve`, unchanged.
- **Environment:** the program gets `$serve` when `--serve` is given.
- **Sandbox defaults:** unchanged. Nothing listens without `--serve`.
- **The root tree:** unchanged. A 9front root's `/bin/exportfs` is used, and the built-in root's otherwise.
- **`third_party/`:** unchanged.
- **Browser host:** `--serve` is an error.

## Security

- **What a client reaches.** The plan's namespace from `--serve-root` down, as the machine's user, through exportfs. devfs's access rules apply: `--read-deny` paths are hidden, read-only paths refuse writes, and `--write=none` adds exportfs's `-R`. A client reaches nothing the guest couldn't. But it does reach almost everything the guest could, including `/mnt/term` and `/srv`. `/net` is left out unless `--serve-net` is given. `--serve-root` narrows it.
- **Who can connect.** Unix sockets are created mode 0600. TCP and WebSocket listeners take whatever host the operator names, including non-loopback addresses. Those without a token, which is every TCP listener, are listed in the plan as served without authentication. There's no default address, so h9 never listens anywhere unasked.
- **Browsers.** WebSocket listeners refuse requests carrying an `Origin` that `--serve-origin` doesn't list, so a page the user visits can't reach a loopback listener. DNS rebinding gets a page's own origin, which is refused the same way.
- **`/net` through a client.** By default the export has no `/net`, so a client can't dial out through the machine. With `--serve-net`, a client that walks to `/net` reaches devip as the guest does, under the guest's `--net` policy, from the host's address, and the plan shows a caveat (`/net served on tcp!0.0.0.0!5640`) for each listener. Under `--net=disable`, `#I` is masked and there's nothing there either way.
- **Notes.** The serving processes are in their own note group, so a note to the program doesn't reach them. The other way, a client acts as the machine's user, so with `/proc` in the export it can write a process's `note` as the guest can. `--serve-root` below `/` leaves `/proc` out.
- **Hostile clients** send anything. exportfs rejects malformed 9P. Frames and buffers are bounded by websocket-9p's limits, connections by the cap of 32, processes by 8 per connection and the serving count, and memory by `--memory`, which serving shares with the program (see Limits).
- **Credentials.** `--serve-token @FILE` keeps the token out of the process listing, and `--print` and `--trace` elide it. A token sent as `?token=` is in the request URL, which a reverse proxy may log. h9 doesn't log request URLs, but an operator using the query form should keep the proxy's logs private or rotate the token.
- **Who connected.** `--trace` logs each accepted connection with its listener and peer: the address for TCP and WebSocket, and the peer's uid and pid for a unix socket (`SO_PEERCRED` on Linux, `LOCAL_PEERCRED` and `LOCAL_PEERPID` on macOS). Nothing is decided by them.

## Done criteria

Integration cases tagged `[serve]`. The client is a second h9, which mounts with a 9P root, a websocket-9p root, or `/net/ws`. HTTP-level cases use a small Zig client from `ws.zig`.

- [x] `test "an h9 root over --serve unix! lists the served tree [serve]"`
- [x] `test "an h9 root over --serve tcp! lists the served tree [serve]"`
- [x] `test "an h9 ws:// root over --serve ws:// lists the served tree [serve]"`
- [x] `test "a guest mounts a --serve ws:// listener through /net/ws [serve]"`
- [x] `test "--serve-root exports only that subtree [serve]"`
- [x] `test "--serve under --write=none refuses writes [serve]"`
- [x] `test "--read-deny paths aren't visible through --serve [serve]"`
- [x] `test "clients see the plan's namespace, not the program's later binds [serve]"`
- [x] `test "listeners close and clients see hangups when the program exits [serve]"`
- [x] `test "a ws:// listener refuses an unlisted Origin with 403 [serve]"`
- [x] `test "a ws:// listener with --serve-token refuses a request without it [serve]"`
- [x] `test "a ws:// listener accepts the token in the query [serve]"`
- [x] `test "the 33rd connection is refused [serve]"`
- [x] `test "clients exporting at the --pids cap don't stop the program's rfork [serve]"`
- [x] `test "--serve with no program serves until a hangup and exits 0 [serve]"`
- [x] `test "--serve tcp!127.0.0.1!0 prints the bound address [serve]"`
- [x] `test "a stale unix socket is replaced and removed at exit [serve]"`
- [x] `test "a unix socket path that isn't a socket exits 125 [serve]"`
- [x] `test "a ws:// listener pings an idle client and closes one that stops answering [serve]"`
- [x] `test "an address in use exits 125 [serve]"`
- [x] `test "a client doesn't see /net without --serve-net [serve]"`
- [x] `test "--serve-net exports /net and the plan shows a caveat [serve]"`
- [x] `test "--serve-origin '*' without --serve-token exits 2 [serve]"`
- [x] `test "a connection past 8 blocking requests fails them without affecting another [serve]"`
- [x] `test "--serve works over a root without /bin/exportfs [serve]"`
- [x] `test "\$serve lists the bound addresses [serve]"`
- [x] `test "an interrupt to the program leaves clients connected [serve]"`
- [x] `test "two runs on one stale unix socket: one listens, one exits 125 [serve]"`
- [x] `test "--print lists listeners and elides the token [serve]"`

Demos:
- [x] `h9 --serve unix!/tmp/h9.sock`, then in another shell `h9 --root unix!/tmp/h9.sock ls /mnt/term`.
- [x] `h9 --serve ws://127.0.0.1:8080/9p --serve-origin http://localhost:8000`, then the browser host's demo page at `?root=ws://127.0.0.1:8080/9p`, once [browser-host](browser-host.md) is built.

## Implementation

1. The server Proc and the per-connection fork and exec of `exportfs`, with a test-only stream source.
2. `src/serve.zig` with unix and TCP listeners (the lock file, stale sockets, port 0, `Machine.serving()`, `$serve`), devhstream's raw streams, `--serve`, `--serve-root`, and `--serve-net`, `Machine.Options`, serve-only runs, the server Proc's note group and exportfs fallback, and the limits, with the separate `--pids` count and the per-connection cap.
3. `ws.zig`'s server side (written for websocket-9p's test relay) wired to WebSocket listeners, with the HTTP checks, `--serve-origin` and `--serve-token`.
4. The plan's `serve` heading, caveats, elision, and `pids` line in `src/policy.zig`, the `--write=none` `-R`, and `--trace`'s connection lines.
5. The dialect slot, empty, ready for [dotl](dotl.md).
6. README: the flags and the demos. SPEC.md: a Serving section, the CLI flag table, and `Machine.Options`. Set `status: implemented`.

## Open issues

- **Live or per-task export.** Clients see a copy of the plan's namespace. A sketch of Wanix rebuilt on hyper9 wants a page to export one task's namespace, and a VM served from the machine loses binds made after its connection started. Both would be another namespace source for the server Proc (see Each connection); which process's namespace, and how to follow it safely, needs its own proposal.
- **A memory cap for serving.** Serving shares `--memory` with the program. If untrusted clients make that a problem in practice, a `--serve-memory` share is the likely fix.

Follow-ups recorded elsewhere: 9P authentication for served TCP in [root-auth](root-auth.md)'s open issues, and serving to the page over a `MessagePort` in [browser-host](browser-host.md)'s updates.

## Updates

**2026-11-09, implementation.** Refinements found while building it:

- `Machine.Options` also has `serve_net: bool`, for `--serve-net`, which the sketch above leaves out.
- There's no test-only stream source (Implementation, step 1). The listeners were built in the same change, so the integration cases drive the per-connection path through real sockets instead.
- The server Proc chooses the exportfs when it starts, by whether `/bin/exportfs` exists in its namespace, so the plan can't know which one runs. The `serve:` heading's comment names both (`# /bin/exportfs, or #Hroot/amd64/bin/exportfs without one`), and each listener's line shows `-R` under `--write=none`.
- A WebSocket client that connects but hasn't finished its handshake after two keepalive periods (60 s) is dropped, so an idle socket can't hold one of the 32 slots.
- The 503 for a WebSocket connection past the cap is written after reading the request, on a short-lived thread, at most 4 at once; past that, the connection is just closed.
- `--serve-token`'s file holds one token, with surrounding whitespace trimmed; a token with spaces in it is a usage error, and a missing file is exit 125.
- A unix socket is created mode 0600 (under a umask of 0177, then `chmod`), like its lock file.
