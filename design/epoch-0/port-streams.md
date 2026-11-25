---
slug: port-streams
title: 9P over a MessagePort
status: implemented
created: 2026-11-13
authors: [progrium]
depends: [browser-host, websocket-9p, serve, dotl, mounts]
areas: [web, kern, cli]
branch: [main]
---

# Proposal: 9P over a MessagePort

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

On the web host, a `MessagePort` carries a 9P connection the way a WebSocket does. The page hands ports to a machine when it creates it, by name. A port can be a [mounts](mounts.md) source (`createMachine({ mounts: [{ port, dst: '/' }] })`), on `/` as the root, anywhere else, or as an [upper-layers](upper-layers.md) up layer the page keeps; a mount in a namespace file (`mount port!home /usr/me`) or the guest's, through `/net/port`; or a connection the machine serves (`createMachine({ serve: port })`, and `machine.serve(port)` while it runs). Each message on the port is one 9P message, in an `ArrayBuffer` that's transferred, not copied. Ports become a third kind of host stream in `src/hstream.zig`, beside WebSocket and accepted streams. So devmnt mounts them through a `#ℓ` conversation like any 9P connection, handed over with `fd` as a WebSocket is, and [serve](serve.md)'s per-connection path serves them. The page can connect two Workers directly, so a machine can use another Worker's file server as its root, with the page out of the data path. Under Node, `worker_threads`' `MessagePort` is the same API, so the integration suite tests it.

## Background

- **The page can only reach a machine through its console.** `createMachine` ([browser-host](browser-host.md)) takes `mounts` of archives, URLs, the built-in root, and `--tmp` ([mounts](mounts.md)), and the Worker's messages carry the console, puts into the root archive, and graphics. A page that serves files in JavaScript, or holds them in another Worker, has to run a WebSocket server to reach the machine, which a page can't do.
- **Both directions were left as follow-ups.** browser-host's Open issues name "a [9P root](ninep-roots.md) over a MessagePort to the page" as an option for a full root. Its 2026-11-06 update and [serve](serve.md)'s Proposal say the per-connection path "takes any devhstream stream, not a socket, so the machine could be served to its embedder over a `MessagePort`, as `createMachine({ serve: port })`", and call that a follow-up proposal. This is it.
- **Host streams already have the shape.** On the web host, `hstream.zig` calls `h9-web.js`'s `h9_ws_*` imports: `ws_open` and `ws_send` return at once, `ws_opened` and `ws_recv` are `Suspending`, and a stream's reader is a coroutine parked in `ws_recv` that takes as many queued binary messages as fit ([spec/host-js.md](../../spec/host-js.md), WebSockets). A port is the same with no handshake and no TLS.
- **Proposals that wait on ports.** [mounts](mounts.md) reserves a `MessagePort` source for `createMachine`'s `mounts`, written `{ port, dst }`. [upper-layers](upper-layers.md) puts a writable layer on the browser host in a tree the page serves, `{ port, dst: '#L', up: true }`, so the page keeps it in memory, IndexedDB, or OPFS. [virtual-loopback](../virtual-loopback.md) gives the web host a loopback and leaves a page reaching a guest server to ports.
- **Wanix.** [Wanix](https://github.com/tractordev/wanix)'s planned split puts its namespace in a Worker of its own, a "namespace kernel", that speaks 9P2000 over MessageChannels, with a host module on the page that hands a port per task to whatever runs the task. For Linux and 9front executables that's an h9 machine, which needs a port root. [namespace-kernel](namespace-kernel.md) is that kernel.

## Proposal

### Handing ports in

`createMachine` takes `ports`, an object from names to `MessagePort`s, transferred to the Worker with the `start` message. A running machine takes more with `machine.addPort(name, port)`. A name is letters, digits, `-`, `_`, and `.`, unique within the machine. A port the machine hasn't opened yet can be replaced; one in use can't. `machine.removePort(name)` hangs up whatever uses it.

Inside, the names are dial strings with the scheme `port`: `port!home`. The page holds the only way to create one, so the guest can name ports but can't make them.

### As a mount source

`mounts` takes `{ port, dst, opts }`, where `port` is a `MessagePort` or the name of one in `ports`. A `MessagePort` given directly is added to `ports` under the next free name of the form `mountN`, so the plan can name it. As a string, the source is `port://NAME`, in `--url`'s syntax: `'--url=port://home:/usr/me:spec=work'`, which `h9-web.js`'s argv takes too. That follows mounts' rule of URLs where a shell or a flag parses the text and dial strings in namespace files.

h9 opens the port before the program runs, hands it to a `#ℓ` conversation with `fd`, as it does a WebSocket it connected, and mounts it with the `spec` option as the attach name, as for any `--url` mount ([spec/ninep.md](../../spec/ninep.md), Mounts and the root). A port can't be redialed, so it doesn't reconnect, whatever its dialect. The options are `--url`'s: `ro`, `rw`, `eph`, and `up`. On `/` it's the root, posted as `/srv/root`, and the built-in root, unions, and the Linux view work over it as over any 9P root. With `up` it's the writable layer over what's beneath it ([upper-layers](upper-layers.md)), and the page decides where the layer's files live.

### In namespace files and the guest

Namespace files mount it by dial string: `mount port!home /usr/me`, and `mount -c port!home /n/x spec` with an attach name. h9 opens the port and hands it to `#ℓ` with `fd`, as for a mount source; `#ℓ`'s `dial` doesn't learn a new network.

In the guest, `#ℏ` serves `port/` beside `ws/`, so `bind -a '#ℏ' /net` puts it at `/net/port`. A conversation's `ctl` takes `open NAME`, and its `data` is the stream, which `dotlfs` and `mount` take as they take a `/net/ws` conversation's. Only the caller's machine's ports are listed. A port can be opened more than once only if the far end answers each `Tversion` as a new session, so h9 opens a port once: a second mount of the same name is "port in use".

### As a served connection

`createMachine({ serve: port })` and `machine.serve(port)` hand a port to serve's per-connection path as an accepted stream, so it gets its own exportfs ([serve](serve.md), or [kernel-serve](kernel-serve.md) once built) of the plan's namespace, under the same rules: `/net` left out unless `serveNet` is set, read-only under `--write=none`, the dialect slot (so a 9P2000.L client works through [dotl](dotl.md)), and the per-connection and total caps. With `serveNet`, the page's client reaches the machine's own loopback through the served `/net`, as any importer of a machine's `/net` does ([virtual-loopback](../virtual-loopback.md)). There's no listener, origin, or token: the page made the port, so it already decided who's on the other end. `--serve` on the web host stays a usage error, since a page can't listen.

### Frames

- Each `postMessage` carries one 9P message as an `ArrayBuffer`, transferred. h9 sends whole messages; on receipt, a message is appended to the stream whatever its boundaries, as for WebSocket binary frames, so a peer that splits or joins messages still works.
- A message that isn't an `ArrayBuffer` or a typed array closes the stream, as a WebSocket text frame does.
- websocket-9p's 16 MiB limit applies to a single message.
- Either side closes by posting `null` and closing the port. A port whose other end was closed, collected, or whose Worker terminated is noticed by the port's `close` event where the runtime fires one (Node does; browser support should be checked in step 1). Elsewhere it isn't noticed, since devmnt has no request timeout: requests wait until the page calls `removePort`, which the host module does when it ends the peer. The stream then hangs up as a WebSocket does.

### The JS host

`h9-web.js` gains `h9_port_*` imports beside `h9_ws_*`: `port_open(name)` returns a handle or an error at once, `port_recv` is `Suspending`, and `port_send` and `port_close` return at once. `hstream.zig`'s web branch gains a port kind that uses them, with the same reader coroutine and wake path as a WebSocket stream. Serving a port registers it with devhstream as an accepted stream.

## Rationale

**A port, not a WebSocket to a local server.** A page can't listen, and a service worker that fakes a WebSocket server would add a hop and a registration for what is a function call between two Workers.

**One 9P message per message.** It costs one `postMessage` per 9P message and lets the buffer be transferred, so a 1 MiB read is one message and no copy across the boundary. A byte stream of chunks would need framing that 9P's own size prefix already gives.

**Names, in dial strings and URLs.** Namespace files, mount strings, and the guest's `mount` take text, and `--print` has to show what was mounted. A name keeps the plan readable and replayable (`--ns` replays `mount port!home` on any machine given a port of that name), and keeps the guest from conjuring ports. It's also how [plan-format](../plan-format.md) names handles that can't be text. A `MessagePort` given straight to `mounts` gets a name for the same reason.

**`fd`, not `#ℓ`'s `dial`.** A WebSocket root is already connected by h9 and handed to `#ℓ` with `fd` ([dotl](dotl.md), Updates), and `dial` reconnects, which a port can't. Ports follow the WebSocket path, and the guest gets them from `#ℏ`, where it gets WebSockets, rather than from a new network in `#ℓ`.

**Opened once.** 9P has no way to tell a server that a new session starts on the same transport except `Tversion`, which resets the connection. A port shared by two devmnt mounts would interleave their tags.

**Served ports skip serve's listener policy.** Origins and tokens exist because anyone on the network can connect to a listener. A port exists only because the page made it and handed it in.

## Compatibility

- **`createMachine`** gains `ports` and `serve`, and `mounts` takes a `port` source. The machine gains `addPort`, `removePort`, and `serve`. Existing calls are unchanged.
- **Dial strings and URLs:** `port!NAME` in namespace files and `port://NAME` in `--url` are new, and only the web host knows them. On native hosts the dial string is "unknown network port" and the URL a usage error, exit 2.
- **`#ℏ`** gains `port/` on the web host. On native hosts it has none.
- **The plan** shows a port mount as `9p` access with the name, and `serve` lists `port NAME` connections.
- **Native hosts:** unchanged.

## Security

- **What the guest can reach:** only ports the page handed in, by name. A guest that mounts `port!x` reaches whatever the page connected to it, under the namespace and policy as for any 9P mount. The network policy doesn't apply, since nothing leaves the page; the plan lists port mounts so they're visible.
- **What a served port can reach:** what serve's per-connection path gives any client, minus `/net` by default. The page is trusted with the port, as it's trusted with the machine.
- **Untrusted peers:** a port from another origin's iframe is as untrusted as a WebSocket client. Its messages go through the same parsing as any 9P stream, and the same caps bound it. Checking the iframe's origin before handing its port in is the page's job, and the docs say so.

## Done criteria

- [x] `createMachine({ mounts: [{ port, dst: '/' }] })` runs `ls /` against a 9P2000 server in another Worker, with the page only creating the channel.
- [x] A namespace file's `mount port!home /usr/me` works, and `--print` shows it.
- [x] `createMachine({ serve: port })`: a JS 9P client on the page lists the machine's `/bin`.
- [x] Cases, under Node's `worker_threads`, tagged `[port-streams]`:
  - `test "a port root serves the program [port-streams]"`
  - `test "a second mount of the same port is refused [port-streams]"`
  - `test "a message that isn't binary closes the stream [port-streams]"`
  - `test "the far end closing hangs up the mount [port-streams]"`
  - `test "a served port leaves out /net [port-streams]"`
  - `test "a 9P2000.L server over a port is translated [port-streams, dotl]"`
  - `test "a port mounts away from the root, with spec as the attach name [port-streams]"`
  - `test "the guest mounts a port through /net/port [port-streams]"`
  - `test "a port up layer takes the guest's writes [port-streams, upper-layers]"`
  - `test "a served port with serveNet reaches the machine's loopback [port-streams, virtual-loopback]"`: waived, see Updates; `test "a served port exports /net with serveNet [port-streams]"` covers `serveNet` itself.
  - `test "port!x and port://x are refused on a native host [port-streams]"`

## Implementation

1. `h9_port_*` in `h9-web.js` and the port kind in `hstream.zig`'s web branch; `ports` and `addPort`.
2. The `port` mount source and `--url port://`, `port!` in namespace files, both handed to `#ℓ` with `fd`, and `#ℏ`'s `port/`.
3. `serve` and `machine.serve`, through serve's accepted-stream path.
4. The Node cases, the Chromium demo, and [spec/host-js.md](../../spec/host-js.md).

## Open issues

- **Detecting a dead peer** where the runtime has no `close` event on ports. A ping message would work but isn't 9P. Relying on the page to call `removePort` may be enough.
- **Publishing to the page.** [virtual-loopback](../virtual-loopback.md)'s `--publish` is refused on the web host. It could hand the page a `MessagePort` per connection to a guest port, through an `onConnect`-style callback, for previews of dev servers in a page. That's raw TCP bytes, not 9P, so it would be a second kind of port stream.
- **Ports between machines.** Two machines in two Workers could mount each other over a port pair the page makes. That's this proposal used twice, but the docs should show it.

## Updates

- 2026-11-25: Done, on the `port-streams` branch. Three things differ from the Proposal as written:
  - The JS host has `port_open`, `port_accept`, `port_stop`, and `port_serving`, but not a `port_recv`, `port_send`, and `port_close` of their own: `port_open` puts the port in the WebSockets' socket table, so `ws_recv`, `ws_send`, `ws_close`, `ws_status`, and `ws_free` take it, and `hstream.zig`'s port kind is a host stream with `port` set that reads through `webReadLoop`. That's the "same reader coroutine and wake path" with less code on both sides.
  - `machine.serve(port)` works on a machine made with `serve` (`true`, a port, or a list): serving forks a server Proc, so h9 decides at start whether it serves (`port_serving`, which sets `Machine.Options.serve_ports` and, with `serveNet`, `serve_net`), rather than every page's machine running one. `--print` lists the served ports as `port`, and they get no "served without authentication" caveat.
  - Under Node the cases' ports come from `h9-node`'s `H9_NODE_PORTS`, a module called with the machine's `Ports`; `tests/web/ports.mjs` relays each port to a 9P server from a `worker_threads` Worker, or listens and hands the machine a port per connection, so a native h9 is the served machine's client. A namespace file's mount isn't in `--print`, which shows the plan, so the namespace-file case checks that `--print` shows a `port://` mount as `mount 'port!home' /usr/me ''` and that the line replays with `--ns`.
- 2026-11-25: The `serveNet` loopback case is waived: it's tagged `virtual-loopback`, which isn't built, and reaching the machine's loopback through a served `/net` is that proposal's. `serveNet` exporting `/net` over a port is tested on its own. Browser support for a `MessagePort`'s `close` event (Open issues) wasn't checked: Node fires it, and where a browser doesn't, a dead peer is noticed when the page calls `removePort`.
