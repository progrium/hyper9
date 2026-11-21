---
slug: port-streams
title: 9P over a MessagePort
status: draft
created: 2026-11-13
authors: [progrium]
depends: [browser-host, websocket-9p, serve, dotl]
areas: [web, kern, cli]
branch: []
---

# Proposal: 9P over a MessagePort

## Abstract

On the web host, a `MessagePort` carries a 9P connection the way a WebSocket does. The page hands ports to a machine when it creates it, by name. A port can be the root (`createMachine({ root: port })`), a mount in a namespace file (`mount port!home /usr/me`), or a connection the machine serves (`createMachine({ serve: port })`, and `machine.serve(port)` while it runs). Each message on the port is one 9P message, in an `ArrayBuffer` that's transferred, not copied. Ports become a third kind of host stream in `src/hstream.zig`, beside WebSocket and accepted streams. So devmnt mounts them through a `#ℓ` conversation like any 9P connection, and [serve](serve.md)'s per-connection path serves them. The page can connect two Workers directly, so a machine can use another Worker's file server as its root, with the page out of the data path. Under Node, `worker_threads`' `MessagePort` is the same API, so the integration suite tests it.

## Background

- **The page can only reach a machine through its console.** `createMachine` ([browser-host](browser-host.md)) takes a root archive or a `ws://` URL, and the Worker's messages carry the console, puts into the root archive, and graphics. A page that serves files in JavaScript, or holds them in another Worker, has to run a WebSocket server to reach the machine, which a page can't do.
- **Both directions were left as follow-ups.** browser-host's Open issues name "a [9P root](ninep-roots.md) over a MessagePort to the page" as an option for a full root. Its 2026-11-06 update and [serve](serve.md)'s Proposal say the per-connection path "takes any devhstream stream, not a socket, so the machine could be served to its embedder over a `MessagePort`, as `createMachine({ serve: port })`", and call that a follow-up proposal. This is it.
- **Host streams already have the shape.** On the web host, `hstream.zig` calls `h9-web.js`'s `h9_ws_*` imports: `ws_open` and `ws_send` return at once, `ws_opened` and `ws_recv` are `Suspending`, and a stream's reader is a coroutine parked in `ws_recv` that takes as many queued binary messages as fit (SPEC.md, Browser host). A port is the same with no handshake and no TLS.
- **Wanix.** [Wanix](https://github.com/tractordev/wanix)'s planned split puts its namespace in a Worker of its own, a "namespace kernel", that speaks 9P2000 over MessageChannels, with a host module on the page that hands a port per task to whatever runs the task. For Linux and 9front executables that's an h9 machine, which needs a port root. [namespace-kernel](namespace-kernel.md) is that kernel.

## Proposal

### Handing ports in

`createMachine` takes `ports`, an object from names to `MessagePort`s, transferred to the Worker with the `start` message. A running machine takes more with `machine.addPort(name, port)`. A name is letters, digits, `-`, `_`, and `.`, unique within the machine. A port the machine hasn't opened yet can be replaced; one in use can't. `machine.removePort(name)` hangs up whatever uses it.

Inside, the names are dial strings with the scheme `port`: `port!home`. The page holds the only way to create one, so the guest can name ports but can't make them.

### As a root

`root` takes a `MessagePort`, or `port!NAME` for one in `ports`. h9 opens it before the program runs, through a `#ℓ` conversation, posts it as `/srv/root`, and mounts it at `/` with `--root-spec` as the attach name, exactly as for a WebSocket root (SPEC.md, Root filesystem). The CLI form, `--root port!NAME`, is accepted by `h9-web.js`'s argv too. Overlay, the built-in root's `--builtin`, and the Linux view work over it as over any 9P root.

### As a mount

Namespace files mount it by dial string: `mount port!home /usr/me`, and `mount -c port!home /n/x spec` with an attach name. The guest's `dotlfs` and `mount` take it the same way, through the `dial` line of a `#ℓ` conversation. A port can be dialed more than once only if the far end answers each `Tversion` as a new session, so h9 opens a port once: a second mount of the same name is "port in use".

### As a served connection

`createMachine({ serve: port })` and `machine.serve(port)` hand a port to serve's per-connection path as an accepted stream, so it gets its own exportfs ([serve](serve.md), or [kernel-serve](kernel-serve.md) once built) of the plan's namespace, under the same rules: `/net` left out unless `serveNet` is set, read-only under `--write=none`, the dialect slot (so a 9P2000.L client works through [dotl](dotl.md)), and the per-connection and total caps. There's no listener, origin, or token: the page made the port, so it already decided who's on the other end. `--serve` on the web host stays a usage error, since a page can't listen.

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

**Names in dial strings.** Namespace files and the guest's `mount` take strings, and `--print` has to show what was mounted. A name keeps the plan readable and replayable (`--ns` replays `mount port!home` on any machine given a port of that name), and keeps the guest from conjuring ports.

**Opened once.** 9P has no way to tell a server that a new session starts on the same transport except `Tversion`, which resets the connection. A port shared by two devmnt mounts would interleave their tags.

**Served ports skip serve's listener policy.** Origins and tokens exist because anyone on the network can connect to a listener. A port exists only because the page made it and handed it in.

## Compatibility

- **`createMachine`** gains `ports` and `serve`, and `root` accepts a `MessagePort` or `port!NAME`. The machine gains `addPort`, `removePort`, and `serve`. Existing calls are unchanged.
- **Dial strings:** `port!NAME` is new, and only the web host knows it. On native hosts it's "unknown network port".
- **The plan** shows a port root as `9p` access with the name, and `serve` lists `port NAME` connections.
- **Native hosts:** unchanged.

## Security

- **What the guest can reach:** only ports the page handed in, by name. A guest that mounts `port!x` reaches whatever the page connected to it, under the namespace and policy as for any 9P mount. The network policy doesn't apply, since nothing leaves the page; the plan lists port mounts so they're visible.
- **What a served port can reach:** what serve's per-connection path gives any client, minus `/net` by default. The page is trusted with the port, as it's trusted with the machine.
- **Untrusted peers:** a port from another origin's iframe is as untrusted as a WebSocket client. Its messages go through the same parsing as any 9P stream, and the same caps bound it. Checking the iframe's origin before handing its port in is the page's job, and the docs say so.

## Done criteria

- [ ] `createMachine({ root: port })` runs `ls /` against a 9P2000 server in another Worker, with the page only creating the channel.
- [ ] A namespace file's `mount port!home /usr/me` works, and `--print` shows it.
- [ ] `createMachine({ serve: port })`: a JS 9P client on the page lists the machine's `/bin`.
- [ ] Cases, under Node's `worker_threads`, tagged `[port-streams]`:
  - `test "a port root serves the program [port-streams]"`
  - `test "a second mount of the same port is refused [port-streams]"`
  - `test "a message that isn't binary closes the stream [port-streams]"`
  - `test "the far end closing hangs up the mount [port-streams]"`
  - `test "a served port leaves out /net [port-streams]"`
  - `test "a 9P2000.L server over a port is translated [port-streams, dotl]"`
  - `test "port!x is unknown on a native host [port-streams]"`

## Implementation

1. `h9_port_*` in `h9-web.js` and the port kind in `hstream.zig`'s web branch; `ports` and `addPort`.
2. `port!` in the dial path of `#ℓ` conversations, roots, and namespace files.
3. `serve` and `machine.serve`, through serve's accepted-stream path.
4. The Node cases, the Chromium demo, and SPEC.md's Browser host section.

## Open issues

- **Detecting a dead peer** where the runtime has no `close` event on ports. A ping message would work but isn't 9P. Relying on the page to call `removePort` may be enough.
- **Ports between machines.** Two machines in two Workers could mount each other over a port pair the page makes. That's this proposal used twice, but the docs should show it.
