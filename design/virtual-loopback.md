---
issue: 315
slug: virtual-loopback
title: A loopback network per machine
status: proposed
created: 2026-11-24
authors: [progrium]
depends: []
areas: [kern, sandbox, cli, linux, web]
branch: []
---

# Proposal: A loopback network per machine

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Give every machine its own loopback network. An `announce` or `bind` on 127.0.0.0/8 or `::1`, and a `connect` to one, stays inside the machine's kernel: devip joins the two conversations with in-kernel queues and never makes a host socket. Two machines can then listen on the same loopback port, a guest can't reach the host's loopback services by accident, and a loopback listen is allowed under `--net=outbound`, which is what build tools such as Mix need. A new `--net=loopback` gives a machine its loopback and nothing else, and `--net=disable` keeps masking `#I`. It becomes the default on every host and backend, and gives the web host a working loopback for the first time. The host's loopback is reached on purpose through a reserved address, `host.h9.internal` (169.254.0.1), opened port by port with `--net-host`. A guest server is published on a host port with `--publish`, which also remaps ports, in the form the Linux VM draft's `publish` already uses. `--net=enable` keeps its meaning for wildcard listens, which answer on the host and inside the machine.

## Background

### h9 today

A guest has no network stack of its own. drawterm's `#I` (`third_party/drawterm/kern/devip.c`) maps each conversation to a host socket through `so_socket`, `so_bind`, `so_connect`, and `so_listen`, and the Linux personality's sockets are devip conversations opened through `/net/tcp/clone` ([linux-net](epoch-0/linux-net.md); `socketCall`, `bindCall`, and `listenCall` in `src/linux/sys.zig`). So:

- **A guest listen is a host listen.** `announce tcp!127.0.0.1!8080` binds the host's 127.0.0.1:8080. A Linux `bind` to `0.0.0.0` becomes devip's `0.0.0.0!PORT`, and the host's wildcard.
- **Ports aren't remapped.** A guest server is on the host port it chose ([containers, section 11](../docs/containers.md#11-networking-and-published-ports)). Two machines, or a machine and a host process, that want the same port collide, and the second gets "address in use".
- **Loopback is the host's.** A guest's `connect` to 127.0.0.1 reaches whatever the host runs there: a dev database, an admin panel, another h9's `--serve` listener on 127.0.0.1:5640. [net-policy](epoch-0/net-policy.md) allowed this on purpose so `h9 mk` could test against a host dev server, and `--print` lists it as a caveat.
- **`--net=outbound` refuses every listen**, loopback included, because a loopback listen is a host listen. Programs that listen on loopback only to talk to themselves fail under the default profile. h9x runs its builds with `--net=enable` only because Mix listens on 127.0.0.1 for its build lock, which also lets the build listen on the host's wildcard.
- **`--net=disable` masks `#I`**, so a program in the tight profile can't use loopback at all, where Linux's `--network none` containers still have `lo`.
- **The web host has no network.** `src/kern/devip-wasm.c` has no sockets, and the policy masks `#I` there, so a guest in a page can't run a server and a client against each other.
- **Machines share devip.** devip's conversation tables are static, so every machine in a host process (an embedder's, or [child-machines](child-machines.md)' children) draws on the same 30 TCP and 10 UDP conversations, and they only stay apart because each conversation is a separate host socket.

Compose-style setups work around this with distinct ports on the host's 127.0.0.1 ([containers, section 15](../docs/containers.md#15-compose-several-machines)): the server runs with `--net=enable` and the client with `--net-allow 'tcp!127.0.0.1!PORT'`.

### Prior art

Linux network namespaces give each container its own `lo`, and that's what Docker and Podman containers see. Host loopback is then reached through a gateway address: Docker's `host.docker.internal`, or slirp4netns's 10.0.2.2, which rootless Podman leaves off unless it's asked for. Published ports (`-p HOST:CONTAINER`) are the way in. Users of those tools already expect a container's 127.0.0.1 to be its own.

## Proposal

### The machine's loopback

Each machine has a loopback: a table of the ports its programs have announced on loopback addresses, and the conversations between them. It belongs to the machine, as the resolved-name table does ([net-policy](epoch-0/net-policy.md)), so two machines in one process never see each other's.

- **Loopback addresses** are 127.0.0.0/8 and `::1`, and their IPv4-mapped forms. A machine answers on every address in 127.0.0.0/8, as Linux's `lo` does.
- **An `announce` on a loopback address** registers the port in the machine's table, and makes no host socket. A port already announced there is "address in use" for that machine only. Port 0 takes a free port from the ephemeral range (32768 to 60999, Linux's default), so `getsockname` after `listen` reports it.
- **A `connect` to a loopback address** looks the port up in the table. If a conversation is announced there, devip makes a new conversation on the listener's side, joins the two with a pair of queues, and the listener's `listen` file returns it. If none is, the connect fails with "connection refused". The client's local address is the address it dialled, and its port comes from the ephemeral range.
- **Data** goes through kernel queues (`qio`), as devpipe's does: a TCP conversation is a byte stream with a hangup at each end, and a UDP one keeps datagram boundaries. A UDP `announce` on loopback receives the datagrams sent to its port, and a UDP send to a loopback port nobody has announced is dropped, as on Linux.
- **Status files** say what Linux and Plan 9 programs expect: `local` and `remote` give the loopback addresses and ports, and `status` the state.
- **Socket options** that have a meaning there are kept (`SO_RCVBUF` and `SO_SNDBUF` size the queues, `SO_REUSEADDR` is accepted), and the rest are accepted and ignored, as Linux does for TCP options on `lo`.
- **Readiness** comes from the queues' own wakeups (`h9_qwake`), as pipes' does, so `poll`, `select`, and edge-triggered `epoll` work on loopback sockets without the host-socket watcher.

Loopback conversations count against the machine's conversation limit like any other, and use no host descriptor.

### Wildcard listens

A wildcard announce (`*`, `0.0.0.0`, `::`, or a Linux `bind` to `INADDR_ANY`) means "every address the machine has", which now includes its loopback.

| `--net` | A wildcard announce | A loopback announce | Any other announce |
| --- | --- | --- | --- |
| `disable` | - (`#I` is masked) | - | - |
| `loopback` | Loopback only | Allowed | Refused |
| `outbound` | Loopback only | Allowed | Refused |
| `enable` | Loopback and the host's wildcard | Allowed | Allowed, on the host |

- **Under `outbound` and `loopback`**, a wildcard announce succeeds and registers on the loopback only. A Linux server that binds `0.0.0.0` by default then runs, answers clients in the same machine, and can be published with `--publish`.
- **Under `enable`**, it does both: it registers on the loopback and announces on the host's wildcard, as today. One conversation then gets calls from two places, and its `listen` file returns whichever comes first. If the host's port is taken, the announce fails, as today.
- **An announce on a specific non-loopback address** is a host announce, allowed only under `enable`, as today.

### Reaching the host's loopback

The host's loopback is reached through a reserved address, **`host.h9.internal`**, which is **169.254.0.1**.

- **`--net-host PORTS`** (repeatable) opens host loopback ports to the guest. PORTS is a dial string without a host, `tcp!5432`, `udp!53`, or `*!8000-8099`, or a bare port or range for TCP (`5432`, `8000-8099`). `--net-host '*'` opens every TCP and UDP port.
- **A `connect` to 169.254.0.1** on an opened port is made to the host's 127.0.0.1 on the same port, by h9, as a host socket. On a port that isn't opened, it's "permission denied", like any refused connect. Without `--net-host`, every port is refused.
- **devip's `cs` translates `host.h9.internal`** to 169.254.0.1 itself, without the host's resolver, and `localhost` to 127.0.0.1 and `::1`, so a lookup of either gives the same answer on every host, the web host included, and under any `--net-allow`.
- **Linux programs** use the address, or the name where the root's `/etc/hosts` lists it. When h9 supplies a Linux root's missing `/etc` files from `#Letc` ([abi-linux](../spec/abi-linux.md)), its `hosts` gains a `host.h9.internal` line beside `localhost`.
- **`--net-allow` patterns don't cover it.** A `connect` to 169.254.0.1 is decided by `--net-host` alone, so `--net-allow '*!*!*'` still doesn't open the host's loopback, and `--net-host` works with or without patterns.
- **The address is otherwise unreachable.** 169.254.0.0/24 is reserved by RFC 3927 and never configured on a link, so the alias can't hide a real host. The rest of link-local stays as net-policy left it.

`--net-host` reaches the host, so it's a usage error with `--net=disable` or `--net=loopback` (exit 2), as `--net-allow` is.

### Publishing a guest port

**`--publish tcp!HOSTADDR!HOSTPORT[!GUESTPORT]`**, or **`--publish PORT`** (repeatable), makes h9 listen on a host port and forward each connection into the machine's loopback.

- **The forms:** `--publish 8080` is `tcp!127.0.0.1!8080!8080`: it listens on the host's 127.0.0.1:8080 and forwards to the guest's 8080. `--publish 'tcp!127.0.0.1!9000!8080'` remaps. `--publish 'tcp!*!8080'` listens on every host address, as Docker's `-p 8080:8080` does. The short form's host address is loopback, not the wildcard, so a published port isn't on the local network unless asked.
- **The same shape as the Linux VM draft's.** That draft publishes a VM port by writing `publish tcp!*!8080 80` to `/dev/linux/ctl`, and leaves a `--publish tcp!*!8080!80` flag as an open issue. This is that flag, and the plan line is the ctl message's form.
- **h9 listens, not the guest.** The listener is h9's own, like `--serve`'s, outside the guest's policy, so publishing works under `outbound` and `loopback` and doesn't need `--net=enable`. Under `disable` there's no loopback to forward to, so it's exit 2. A host port that can't be listened on is exit 125, as `--serve`'s is.
- **Each host connection** becomes a loopback connect to GUESTPORT, made by h9 for the machine. If nothing is announced there, h9 closes the host connection at once. A guest server that starts later gets the connections that arrive after it announces.
- **The guest sees the call come from `host.h9.internal`**, not from 127.0.0.1, so a server that trusts loopback peers doesn't trust the host's network by mistake.
- **UDP** isn't published in this proposal (see Open issues).

h9x's `--listen 8080` becomes `--publish 8080` on an `outbound` machine.

### Several machines

- **Separate h9 processes** each have their own loopback. Two machines talk through the host: one publishes, the other opens that port with `--net-host` and dials `host.h9.internal`. That replaces `--net=enable` on the server and `--net-allow 'tcp!127.0.0.1!PORT'` on the client, and each machine can reach only the port it was given.

  ```sh
  h9 --dir ./images/greeter --ns /app/ns --publish 8080 --env port=8080 serve &
  h9 --net-host 8080 --rc 'hget http://host.h9.internal:8080/'
  ```

- **Machines in one process** (an embedder's) each get their own loopback. Two that should share one, as the containers in a Kubernetes pod share a network namespace, do it the Plan 9 way: one mounts the other's `/net` (below), and its dials and announces are then the other machine's. There's no shared loopback object, in keeping with [kernel-port](kernel-port.md)'s rule that two machines in a process share nothing unless one is handed a channel into the other.
- **A child machine's host is its parent.** Under [child-machines](child-machines.md), a child gets its own loopback, its `host.h9.internal` is its parent's loopback, and its `--publish` listens on its parent's loopback. `#μ` takes `nethost` and `publish` lines like the CLI's flags. A child's `nethost` can't be broader than what reaches the parent, since it only reaches the parent's loopback, so nesting needs no new narrowing rule.
- **A mounted `/net` is the machine that serves it.** With `--serve-net`, an `.fd` mount ([fd-mounts](epoch-0/fd-mounts.md)), a served `MessagePort` ([port-streams](epoch-0/port-streams.md)), or anything else that imports a machine's `/net`, the importer's loopback dials and announces are that machine's, as importing a Plan 9 machine's `/net` gives you its network. The Linux layer already dials through whatever `/net` is mounted (`conv_remote` in `src/linux/sys.zig`).

### The web host

The web host binds `#I` with a loopback and nothing else, beside [websocket-9p](epoch-0/websocket-9p.md)'s `/net/ws`: every non-loopback announce and connect is refused, `cs` answers only `localhost`, `host.h9.internal`, and literal addresses, and `--net-host` and `--publish` are refused, since the page has no host sockets. A guest in a page can then run a server and its clients, such as a dev server and the tests against it, or, under the js-runtime draft, a Node server whose sockets are syscalls to h9. A page reaching a guest server is left to [port-streams](epoch-0/port-streams.md) (see Open issues).

### How it fits the other proposals

- **The Linux VM draft** gives the VM a slirp-style link whose gateway, 10.0.2.2, the netproxy Proc dials as 127.0.0.1 through devip. Under this proposal that dial reaches the machine's loopback, so the gateway stands for the machine, which is what h9's 127.0.0.1 now means, as a container's gateway does: a program in the VM reaches a 9front or Linux-personality server in the same machine at 10.0.2.2, and the host's loopback at `host.h9.internal` like any other program, under `--net-host`. Its `publish` ctl message announces through devip as before, so `publish tcp!127.0.0.1!8080 80` is a loopback announce that `outbound` allows, and `--publish` takes it the rest of the way to the host. Its test that `wget` reaches a server on the host's loopback through 10.0.2.2 gains `--net-host` and dials `host.h9.internal`.
- **[host-handles](host-handles.md)** gives the kernel a `dial` and a `listen` handle, and makes `--net disable` mean neither. The loopback needs no handle, since it never leaves the kernel, which is why it can exist under `loopback` and on the web host. `--publish`'s listeners and the `host.h9.internal` dials are made through the `listen` and `dial` handles, so a plan with neither opens nothing on the host.
- **[kernel-port](kernel-port.md)** makes the kernel an instance with no globals. The loopback table is one of its tables, and devip's static conversation tables, which machines share today, become per-instance there too.
- **[file-interface](file-interface.md)** moves readiness to `ready` and `watch` on every channel, starting with queues and pipes. Loopback conversations are queues, so they get it with no work of their own. Until then, they use the `h9_qwake` path that pipes use.
- **[child-machines](child-machines.md)** and **[plan-format](plan-format.md)** gain `nethost` and `publish` lines, as above.
- **[net-policy](epoch-0/net-policy.md)** is refined, not replaced: its modes, patterns, link-local rule, and `cs` checks all stand, and they now describe the network outside the machine.

### The policy and the plan

- **`net.loopback`** joins the capability table: "loopback addresses are the machine's own; devip makes no host socket for them". `enforces:` lists it whenever `#I` is bound.
- **`--net=loopback`** is a new mode between `disable` and `outbound`: `#I` is bound, every non-loopback announce and connect is refused before a host socket is made, `cs` resolves only `localhost` and literal addresses, and `/net/ws` stays masked. `enforces:` lists it as `net.local`.
- **`--net=disable`** is unchanged: `#I` is masked, so the machine has no loopback either, and devip can't be reached at all. The tight profile's default stays `disable`.
- **The order** for narrowing ([child-machines](child-machines.md), [plan-format](plan-format.md)) is `disable` < `loopback` < `outbound` < `enable`.
- **`--net-allow` patterns** describe the network outside the machine. A connect to the machine's loopback is never checked against them. A pattern whose whole address range is loopback, such as `tcp!127.0.0.1!8080`, would match nothing, so it's a usage error (exit 2) whose message names `--net-host` and `--publish`.
- **Plan lines** ([plan-format](plan-format.md)): `nethost tcp!5432` and `publish tcp!127.0.0.1!9000 8080`. Both widen, so a flag after `--plan` can drop one but not add one.
- **`--print`** prints `net-host:` and `publish:` sections after `net-allow:`. The caveat "outbound connections can reach any address the host can except link-local, including its loopback and local network" loses "its loopback". New ones:

| Setup | Caveat |
| --- | --- |
| `--net-host` | "the guest can reach the host's loopback on PORTS, through host.h9.internal" |
| `--publish` on a non-loopback host address | "published port PORT is reachable by anything that can reach the host on ADDR" |
| `enable` | "servers in the guest that listen on * are reachable by anything that can reach the host's ports; ones on 127.0.0.1 only from inside the machine" |

### CLI and API

| Flag | Meaning |
| --- | --- |
| `--net-host PORTS` (repeatable) | Opens host loopback ports to the guest, at `host.h9.internal` (169.254.0.1) |
| `--publish tcp!HOSTADDR!HOSTPORT[!GUESTPORT]`, `--publish PORT` (repeatable) | h9 listens on the host port and forwards to the guest's loopback port |

`Policy` gains `net_host`, and `Machine.Options` gains `publish`.

## Rationale

**Loopback in the kernel, not the host.** The alternatives were per-machine host network namespaces (Linux only, needs privileges or user namespaces, and nothing like it on macOS, Windows, or the web host), or rewriting loopback addresses to host ports (h9 would still hold a host port per guest listen, and two machines would still compete for the host's port space). A table and queues in devip behave the same on every host and backend, need no privilege, and cost no host descriptor.

**Queues, not host socketpairs.** A loopback connection could be a host `socketpair`, which would let devip's existing `sfd` paths, the host-socket watcher, and `h9so_recvfrom`'s `MSG_PEEK` work unchanged. It was rejected because the web host has no sockets, Windows has no `socketpair` for `AF_UNIX`, every loopback connection would cost two host descriptors, and the `local` and `remote` files would still need h9's addresses. Queues are what pipes already use, with readiness already wired for them.

**Default, not opt-in.** It fixes the collisions for everyone, lets `outbound` run programs that listen on loopback (Mix, test suites that start a server, an in-guest database), and closes the host's loopback services to guests that didn't ask for them, h9's own `--serve` listener among them. The cost is that a guest can no longer reach a host dev server at 127.0.0.1 without saying so. net-policy allowed that to keep `h9 mk` against a host server working, and `--net-host` now keeps it working with one flag, scoped to the ports it needs. Docker and Podman users already expect a container's 127.0.0.1 to be its own.

**A reserved address, not falling through to the host.** A connect to the guest's 127.0.0.1 on a port nobody in the guest announced could go to the host instead, so existing configs that say `localhost:5432` keep working. It was rejected because where a connection goes would depend on timing: a client that tries before its in-guest server announces would reach the host's server on the same port. A separate address makes the destination part of what the guest dialled.

**169.254.0.1, not a private or loopback address.** An address in 10.0.0.0/8 or 192.168.0.0/16, as slirp4netns and Docker Desktop use, could shadow a real host on the user's network. Carving one out of 127.0.0.0/8 would break programs that bind other loopback addresses. 169.254.0.0/24 is reserved and never assigned, so the alias shadows nothing, and link-local is already special to h9's policy.

**`--net-host` beside `--net-allow`, not inside it.** Under `--net-allow` the patterns are the whole policy, so opening one host port through a pattern would close the rest of the network. A pattern like `*!*!*` would also open the host's loopback by accident. Keeping the host's loopback under its own flag means each flag means one thing.

**No `--loopback host` to keep today's behaviour.** A switch that gives the guest the host's loopback again would bring back the collisions and the open host services for every port, to save one flag. `--net-host '*'` and `--publish` cover what it would, with each direction said separately.

**Publishing by h9, not by `--net=enable`.** Publishing a port is a decision by the person running the machine, so the listener is h9's, as `--serve`'s is. The guest only listens on its own loopback, and `--net=enable` stays the one way a guest can open host ports itself.

**Published calls from `host.h9.internal`, not 127.0.0.1.** Servers often trust loopback peers, for an admin port or an unauthenticated debug endpoint. Calls that came from outside the machine shouldn't get that trust, and Docker's published ports likewise arrive from the bridge's gateway, not from the container's loopback.

**A `loopback` mode, not loopback under `disable`.** Giving `disable` a loopback would let the tight profile run programs that only talk to themselves, but masking `#I` is a stronger guarantee than a refusal in devip, and some runs want devip out of reach entirely. Renaming today's `disable` to `none` and giving `disable` the loopback would change what every existing `--net=disable` means. A new mode keeps `disable` as it is and makes the loopback-only machine one word away.

## Compatibility

- **Guests that reach host loopback services** stop reaching them: a connect to 127.0.0.1 on a port nothing in the guest announced is "connection refused". They need `--net-host PORT` and `host.h9.internal`.
- **Host clients of guest servers on 127.0.0.1** stop reaching them, even under `--net=enable`. They need `--publish`. Servers on `*` under `--net=enable` are reachable from the host as before.
- **`--net=outbound`** now allows loopback and wildcard announces, on the machine's loopback only. Scripts that used `--net=enable` only for that, as h9x's builds do, can drop it.
- **`--net=disable`** is unchanged. **`--net=loopback`** is new, and `#μ` and plan `net` lines take it.
- **`--net-allow` with a loopback-only pattern** is exit 2, naming `--net-host`. net-policy's case `a name pattern allows a connect through cs` used `tcp!localhost!PORT` against a host listener; it moves to a non-loopback address.
- **`cs`** answers `localhost` and `host.h9.internal` itself.
- **h9's own tests** dial listeners the test opens on the host's 127.0.0.1 (net-policy's and the backend tests' `expectNet` cases, and `tests/dotlserver.zig`), and 9p-roots' cases serve from a second h9 on `tcp!127.0.0.1!PORT`. They move to `--net-host` and `host.h9.internal`, or to `--publish`, in the same change.
- **New flags** `--net-host` and `--publish`, new plan lines `nethost` and `publish`, and new `Machine.Options` and `Policy` fields. Nothing existing changes meaning except as above.
- **`--print`:** `net.loopback` in `enforces:`, two new sections, and the caveats above.
- **Docs:** [containers](../docs/containers.md) sections 11 and 15 and the manual's networking chapter change their recipes to `--publish` and `--net-host`.
- **Vendored tree:** `devip.c` gains the loopback branches at `announce`, `connect`, the `listen` open, and its read, write, and close paths, as calls into h9's own `src/kern/loopback.c`. `scripts/vendor-drawterm.sh` merges them across upstream updates.

## Security

- **What the guest can no longer reach by default:** every service on the host's loopback, including databases, admin interfaces, and other h9 machines' `--serve` listeners. Under `--net-host` it reaches only the ports named.
- **What the guest newly can:** listen on its own loopback under `outbound` and `loopback`. That reaches nothing outside the machine: the only ways in are `--publish`, which the person running it chose, and `--net=enable`, as before.
- **Published ports** listen on the host's loopback unless an address is given, so publishing doesn't open the local network by accident, and `--print` lists a non-loopback one as a caveat. Calls arrive from `host.h9.internal`, so they don't get the trust a guest server gives loopback peers.
- **Isolation between machines in one process** rests on the per-machine table. A machine reaches another's loopback only through that machine's `/net`, mounted on purpose. Tests cover two machines on one port in one process.
- **The alias** is checked before the policy's link-local rule and decided only by `--net-host`, so `--net-allow` patterns can't open it, and it can't be used to reach other link-local addresses: h9 rewrites only 169.254.0.1, and only to the host's 127.0.0.1.
- **`loopback`** runs devip code with no way out: every path to a host socket goes through the same check, before the socket exists, and a test shows a host listener sees nothing. Those who want devip unreachable use `disable`, which masks it as before.

## Done criteria

Integration cases tagged `[virtual-loopback]`, using rc's writes to `/net` ctl files and Linux programs from the Alpine fixture:

- [ ] `test "two machines listen on the same loopback port [virtual-loopback]"`: two h9 processes each run `aux/listen1 -t tcp!127.0.0.1!PORT` while the test holds the host's 127.0.0.1:PORT, and each answers its own client.
- [ ] `test "outbound allows a loopback listen [virtual-loopback]"`: `listen1` on `tcp!127.0.0.1!PORT` and a client in the same machine, under the default profile.
- [ ] `test "a wildcard listen under outbound is loopback only [virtual-loopback]"`: a Linux server on `0.0.0.0` answers a Linux client on 127.0.0.1, and the host can't connect.
- [ ] `test "a guest loopback listener isn't reachable from the host [virtual-loopback]"`, under `--net=enable`.
- [ ] `test "a wildcard listen under enable answers the host and the guest [virtual-loopback]"`
- [ ] `test "a guest can't reach the host's loopback by default [virtual-loopback]"`: a connect to the test's listener on 127.0.0.1 is refused, and to 169.254.0.1 is "permission denied", and the listener sees nothing.
- [ ] `test "--net-host opens one host port through host.h9.internal [virtual-loopback]"`, and another port stays refused.
- [ ] `test "--net-allow doesn't open host.h9.internal [virtual-loopback]"`: under `--net-allow '*!*!*'`.
- [ ] `test "--publish forwards a host port to a guest port [virtual-loopback]"`, with `tcp!127.0.0.1!9000!8080`, and the guest's `remote` is 169.254.0.1.
- [ ] `test "a published port with no guest listener closes [virtual-loopback]"`
- [ ] `test "--net=loopback gives loopback and nothing else [virtual-loopback]"`: a loopback server and client work, and a connect to the test's host listener is refused.
- [ ] `test "--net=disable still masks #I [virtual-loopback]"`
- [ ] `test "UDP on loopback keeps datagrams [virtual-loopback]"`
- [ ] `test "epoll on loopback sockets [virtual-loopback]"`: an edge-triggered server and client in Linux.
- [ ] `test "cs translates localhost and host.h9.internal [virtual-loopback]"`
- [ ] `test "a loopback-only --net-allow pattern is a usage error [virtual-loopback]"`
- [ ] `test "--print shows net-host, publish, and net.loopback [virtual-loopback]"`
- [ ] `test "two machines in one process don't share loopback [virtual-loopback]"`: a unit or backend test on `Machine`.
- [ ] Web: `await test('a loopback server and client on the web host [virtual-loopback]', ...)` in `tests/web/`.
- [ ] Demo: an Elixir project from h9x's examples builds with `--net=outbound`.

## Implementation

1. `src/kern/loopback.c`: the per-machine port table, conversation pairs over `qio` queues, ephemeral ports, and readiness through `h9_qwake`. Unit tests for the table.
2. The branches in `devip.c`: loopback `announce`, `connect`, the `listen` open (with both sources for a wildcard under `enable`), read, write, close, and the status files. `cs` answers `localhost` and `host.h9.internal`.
3. `src/kern/linuxnet.c` and `src/linux/sys.zig`: readiness, `shutdown`, `SO_ERROR`, `recvfrom` and `sendto` with `MSG_PEEK` on loopback conversations, and `bindCall`'s wildcard handling.
4. The policy: `net.loopback`, the `loopback` mode, loopback under `outbound`, `net_host` and the 169.254.0.1 rewrite, the loopback-pattern usage error, `--print`, and the caveats.
5. `--publish`: h9's host listeners and the forwarding, with exit 125 on a port that can't be listened on.
6. The web host: `#I` bound with loopback only.
7. `#Letc`'s `hosts` line, and `nethost` and `publish` for `#μ` if [child-machines](child-machines.md) is in by then.
8. Existing tests that dial the host's loopback move to `--net-host` or `--publish`. The integration and web cases, then docs: MANUAL.md's networking chapter, docs/containers.md sections 11 and 15, and the spec (`spec/sandbox.md`, `spec/cli.md`, `spec/abi-linux.md`, and `spec/machine.md`). Set `status: implemented`.

## Open issues

- **IPv6 for the alias.** 169.254.0.1 reaches the host's 127.0.0.1 only. A host service on `::1` alone isn't reachable. An IPv6 alias would need an address that can't be routed and doesn't need a zone, as `fe80::` does.
- **Publishing UDP.** `--publish 'udp!…'` would need h9 to keep a flow table per host peer. Nothing needs it yet.
- **A page reaching a guest server.** On the web host, `--publish` could hand the page a `MessagePort` per connection, through [port-streams](epoch-0/port-streams.md), for previews of dev servers in a page.
- **Linux DNS names.** Programs that resolve with their own DNS client, not `/etc/hosts`, won't find `host.h9.internal`. Whether h9 should answer for it there depends on h9 seeing those queries, which it doesn't today.
