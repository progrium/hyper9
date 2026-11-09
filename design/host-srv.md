---
slug: host-srv
title: Posting host connections to /srv
status: draft
created: 2026-11-06
authors: [progrium]
depends: [8, 13, 21]
areas: [cli, kern]
---

# Proposal: Posting host connections to /srv

## Abstract

h9 can connect to 9P servers on the host side and post each connection in the machine's `/srv` before the program starts: `--srv name=tcp!host!564`, `--srv name=unix!/run/fs.sock`, or `--srv name=wss://fs.example/9p`. Namespace files and guest programs mount them as `mount /srv/name /n/x`, as on 9front. h9 only connects and posts; the attach, with its spec and user, is made by whoever mounts the entry. Embedders can post a connection they've already opened, such as one end of a socketpair served by their own 9P server. This generalises how [9p-roots](0013-9p-roots.md) posts its root as `/srv/root`, and is the client-side counterpart of [serve](0035-serve.md).

## Background

- **9p-roots** connects to one server, posts its channel to `#s/root` by creating the entry and writing the connection's fd number into it, and mounts it at `/`. A guest can mount `/srv/root` again at another path, with another spec. Nothing else is posted by the host.
- **[devsrv](0008-devsrv.md)** gives each machine its own `/srv` board. Its compatibility notes say `mount /srv/x …` lines in a namespace file work only if something posted `/srv/x` before the replay, which in practice nothing does.
- **[websocket-9p](0021-websocket-9p.md)** lets a namespace file mount a `ws://` or `wss://` URL directly: h9 connects a new stream for that line and mounts it. A `tcp!` or `unix!` source in a namespace file isn't accepted; it's opened as a guest path, which fails, and newns skips the line. Each URL line is its own connection, mounted at one place, with no name the guest can mount again.
- **In the guest,** 9front's `srv tcp!fs!564 fs` dials through `/net`, under [net-policy](0005-net-policy.md), and posts the connection. It needs `srv` in the root (the built-in root's box has it), it can't reach a unix socket, a WebSocket, or anything else devip doesn't dial, and it runs once the program does, so a namespace file can't mount what it posts.
- **Embedders** who want to serve a host directory with their own 9P server, rather than devfs, have no way to hand the connection to the machine. Their only route is a listening socket that `--root` or the guest dials, which puts a listener on the host for something that never needed one.
- **[serve](0035-serve.md)** is the other direction: h9 listens, and each accepted connection gets an `exportfs` of the machine's namespace. Its export includes `/srv`.

## Proposal

### `--srv`

| Flag | Meaning |
| --- | --- |
| `--srv NAME=ADDR` | Repeatable. Connect to the 9P server at ADDR before the program starts, and post the connection as `/srv/NAME` |

ADDR takes `--root`'s connection forms, read the same way:

- **`tcp!host!port`**, or `tcp!host` for port 564: dialed through devip.
- **`unix!path`:** a unix-domain socket. A bare host path is a unix socket too if it is one; anything else is an error ("srv fs: /run/fs.sock: not a socket"), exit 125. A directory isn't accepted, since posting is for connections.
- **`ws://…`** and **`wss://…`:** a 9P server over a WebSocket, connected as websocket-9p connects a namespace file's URL: through `Machine.Options.proxy`, trusting the host's certificate bundle, with no extra headers. A token goes in the URL's query.

NAME is a devsrv entry name: not empty, with no `/`, and not `.`, `..`, `clone`, or `root`. `root` is 9p-roots' post, whether or not the run has a 9P root, so a namespace file's `mount /srv/root` always means the root's server.

These are usage errors (exit 2):

- a value without `=`, a NAME devsrv would refuse, `root`, or a NAME given twice;
- an ADDR in none of the forms above;
- `--srv` with `--write=none` (see The policy);
- a `tcp!` or `unix!` ADDR on the [browser host](0012-browser-host.md), which has only the page's WebSocket.

A connection that fails before the program runs exits 125 with the cause, as a root's does: `srv fs unix!/run/fs.sock: connection refused`, `srv web wss://fs.example/9p?…: server answered 401 Unauthorized`. A unix socket on a Windows host exits 125 with "unix sockets need a POSIX host", as for roots (see Rationale).

### Connecting and posting

In the machine's first Proc, after the root is connected, posted, and mounted, and before any other bind and before the device mask is set, h9 handles each entry in the order given:

1. **Connect.** A TCP entry is dialed through `#I/cs` and `#I/tcp/clone` by device path, with the machine's plan cleared for the dial, exactly as a TCP root is, so neither `--net` nor `--net-allow` sees it. A unix socket is connected by `h9_unixdial` and wrapped with devlfd's `lfdchan`. A URL is connected as a framed devhstream stream.
2. **Post** the channel to the machine's board as `#s/NAME`, mode 0666, by creating the entry and writing the fd number into it, as 9p-roots does. The board holds the channel; h9 closes its own fd.
3. **Nothing more.** h9 sends no `Tversion` and no `Tattach`. The first mount of `/srv/NAME` negotiates the version, and each mount attaches with the spec it names and the mounting process's user as `uname`, which is the machine's user. A server that wants authentication, or speaks a dialect devmnt doesn't, fails that mount, not the run (see Rationale).

Then the plan's binds run, including `#s` at `/srv`, then the device mask, then the `--ns` replay, then the program. So a namespace file and the program both see every entry.

**Sharing a connection.** Every mount of `/srv/NAME` goes over the one connection, as on 9front: devmnt multiplexes attaches on a channel. A namespace file can mount a server's `work` tree at `/n/work` and its `src` tree at `/n/src` with one connection, and a program can attach it again later at a third path.

**Lifetime.** The board holds each entry for the machine's life, and the machine's end closes the connection with everything else. The guest owns the entries it sees, as the machine's user, so it can remove one; that drops the board's reference, and mounts already made keep the connection until they're unmounted, as on 9front. A server that hangs up fails the guest's operations with "i/o on hungup channel", and h9 doesn't reconnect, as for roots.

### Namespace files and the guest

```text
$ h9 --srv fs=unix!/run/fs.sock --srv src=tcp!fs.example!564 --ns build.ns mk
```

with `build.ns` holding

```text
mount -c /srv/fs /n/fs
mount /srv/src /n/src work
bind -c '#O' /n/src
```

mounts the unix socket's server at `/n/fs`, writable through to that server, and the TCP server's `work` tree at `/n/src` under a fresh copy-on-write overlay, so writes there stay in memory ([ephemeral-writes](0006-ephemeral-writes.md)'s bare `#O`). The mount points must exist in the root, as for any mount. newns needs nothing new: these are ordinary mounts of posted channels, the kind devsrv already says it supports.

In the guest, the same lines work in rc: `mount /srv/fs /n/fs` goes through `amount`, whose `fauth` gets "authentication not required" from a server that doesn't authenticate, and mounts. `/proc/n/ns` prints such a mount as `mount /srv/fs /n/fs`, from devsrv's `srvname`, not as the channel's own path, so `ns` output replays with `--ns` in another run given the same `--srv`, and the guest's view doesn't show the socket's host path.

### `Machine.Options`

```zig
pub const Srv = struct {
    /// The entry's name under /srv. Not `root`.
    name: []const u8,
    source: Source,

    pub const Source = union(enum) {
        /// `tcp!host!port`.
        tcp: []const u8,
        /// A unix-domain socket's host path. POSIX hosts only.
        unix: []const u8,
        /// A `ws://` or `wss://` URL.
        ws: []const u8,
        /// A connected host socket or pipe the caller opened. The machine
        /// owns it from `init` and closes it when the machine ends, or when
        /// `init` fails. POSIX hosts only.
        fd: std.posix.fd_t,
    };
};
srv: []const Srv = &.{},
```

`Source` isn't `Root`: a root can be a host directory, which isn't a connection, and only an embedder can hand over an fd. The three shared forms are parsed by the same code.

An `fd` source is wrapped with `lfdchan`, as a unix socket is, so it can be anything that reads and writes 9P messages: one end of a `socketpair` whose other end the embedder serves from a thread, a pipe pair, or a socket inherited from a supervisor. Nothing listens. On the browser host, `createMachine({ srv: { web: "wss://…" } })` takes URL sources only.

### The plan

`--print` lists the entries under a `srv` heading of their own, after `namespace`, in the order given. A URL's query is elided, as for a WebSocket root:

```text
srv:
  fs        unix!/run/fs.sock
  src       tcp!fs.example!564
  web       wss://fs.example/9p?…
caveats:
  - writes to servers posted in /srv go to those servers, which decide what can be written
  - the connections to src and web aren't encrypted
  ...
```

The heading is outside `namespace`, so a saved namespace isn't changed and newns has nothing new to parse. A `ws://` or TCP entry gets the unencrypted caveat; `wss://` and unix sockets don't. The run's `mount /srv/…` lines show in `namespace` only when they come from `--ns`, as the file's other lines do.

`--trace` logs each connection as it's made, with its name and its address with any query elided, and each failure.

### The policy

- **The network policy** doesn't apply, as for a root's connection: h9 makes it, from an address the operator named, before the mask. `--net=disable` still masks `#I`, so the guest can't dial anything itself, and it can't dial anything else through a posted connection, which goes to one server.
- **Writes** go to each server, which decides what's writable, as for a 9P root. h9 can't make devmnt read-only, and the guest makes the mounts, so `--write=none` with `--srv` is exit 2: "--write=none can't be enforced on servers posted with --srv". Under `--write=scope`, the default, the plan's caveat says so. A namespace file that wants writes kept off a server binds a bare `#O` over its mount, as above. [overlay](0011-overlay.md)'s default overlay covers the root, not mounts made after it.
- **Limits:** each entry is one host connection, fixed by the command line, and costs a devmnt channel per mount. `--memory` and `--pids` count what the guest does with them, as always.

### Other proposals

- **[serve](0035-serve.md).**
  - **Clients reach posted servers.** serve exports `/srv` with the rest of the namespace, so a client can open `/srv/fs` through exportfs and mount it, as `import`ing `/srv` does on 9front, reaching the host's server through the machine as the machine's user. When a run has both, and `--serve-root` is `/`, the plan adds a caveat: `servers posted in /srv are reachable through --serve on tcp!0.0.0.0!5640`. `--serve-root` below `/` leaves `/srv` out.
  - **Mounts of posted servers** made by `--ns` are in the plan's namespace, so serve's snapshot has them at their mount points. Mounts the program makes later aren't, but the board isn't part of the namespace, so a client can still mount any entry through `/srv`.
  - **Gateways.** The two compose into a bridge with h9's policy in the middle: `h9 --srv up=unix!/run/fs.sock --ns gw.ns --serve ws://127.0.0.1:8080/9p --serve-origin http://localhost:8000` makes a unix socket server reachable from a browser tab, through `--serve-root`, `--read-deny`, and `--write`. With [dotl](0022-dotl.md), the same bridge translates between 9P2000 and 9P2000.L.
  - **Two h9s.** `h9 --serve unix!/tmp/a.sock`, then `h9 --srv a=unix!/tmp/a.sock --rc` mounts the first machine's namespace in the second with `mount /srv/a /n/a`. That's the demo once serve is built.
  - **Raw devhstream streams.** serve adds devhstream's raw host-made streams for its accepted connections. Once they exist, `unix` and `fd` sources move onto them, which brings both to Windows (see Rationale). Nothing here waits for that.
  - **Naming.** serve's plan heading is `serve` and this one's is `srv`, after the flags. Each lists what it opened, so a run with both shows its inbound and outbound connections side by side.
- **[9p-roots](0013-9p-roots.md).** The root is the one entry h9 also mounts. Its connect and post code is split out and shared, and `root` stays its name. `--root-spec` and `--root-user` have no `--srv` counterparts, since h9 doesn't attach.
- **[websocket-9p](0021-websocket-9p.md).** `ws` sources connect as its namespace-file mounts do. Those mounts are unchanged: a URL on a `mount` line still makes its own connection.
- **[dotl](0022-dotl.md).** dotl puts roots' and namespace files' connections through its translator before devmnt sees them. Posted connections go through it the same way, before the post, so `--srv z=tcp!zerofs.example!5564` posts a translated channel and the guest's `mount /srv/z` works unchanged. Until dotl is built, a .L server fails the guest's mount at `Tversion`.
- **[root-auth](root-auth.md).** h9 doesn't authenticate posted connections. A guest that holds a key in its own factotum can authenticate its own mount, since `amount` calls `fauth`; h9 doesn't give it one. Host-side authentication for entries is an open issue.
- **[child-machines](0109-child-machines.md).** A child's `#s` board is fresh, so it sees none of its parent's entries. Handing one over would be a `ctl` line there, naming a caller's `/srv` path to post on the child's board, under its rule that a child reaches only what the caller can.

## Rationale

**Connecting on the host, not letting the guest dial.** A guest's `srv` can post a TCP connection, but not a unix socket, a WebSocket through the host's proxy, or an embedder's fd, and it runs after the namespace is built, so namespace files can't use it. It also goes through `--net`, which is right for the guest's own connections and wrong for a server the operator named: a run under `--net=disable` that needs its build cache from a 9P server shouldn't have to open the network to the guest to get it. Connecting before the mask is what 9p-roots does for the same reasons, and the plan lists every entry, so nothing is reached that `--print` doesn't show.

**Posting, not mounting.** A `--srv` that also took a mount point would be a second, smaller namespace language beside `--ns`, without its flags or ordering. Posting leaves placement to newns, which already has `mount` with `-a`, `-b`, `-c`, and a spec, and gives the guest a name it can mount again later with another spec, as on 9front.

**Not dial strings in namespace files.** websocket-9p made URLs work as `mount` sources, and `tcp!` and `unix!` could be added the same way. But a namespace file is a guest path read during the replay, after the policy is compiled, so its connections can't be in the plan, and conflicts like `--write=none` are found late, as websocket-9p's updates note (exit 125 rather than 2). Each line is also its own connection, mounted once, and an embedder's fd has no text form at all. `--srv` makes each connection a plan entry with a name, and namespace files refer to it by that name. The two don't conflict, and dial strings in namespace files are an open issue.

**No attach at startup.** The spec and the user belong to the mount, and an entry may be mounted several times with different specs, or not at all. Sending `Tversion` early would catch a server that speaks the wrong dialect, but devmnt negotiates on the first mount anyway, and a guest's own `srv` post fails the same way at mount. A failed connection, which is the common case of a wrong address or a stopped server, is still caught before the program runs.

**Posting the connection, not a placeholder or a device.** As in 9p-roots, `/srv/NAME` is a name 9front already has: newns, `mount`, `ns`, and `/proc/n/ns` work with it unchanged. A placeholder like `<srv:fs>` would need its own syntax in newns, and a device per entry would be a second registry beside devsrv.

**`lfdchan` for unix sockets and fds, for now.** It's what 9p-roots' unix roots use, so this adds no transport. devhstream's raw streams, which serve adds, would carry the same bytes through a reader thread and work on Windows, where a winsock handle can't go through devlfd's `ReadFile` and `WriteFile`. Moving every host-made connection onto them is one change, for roots and entries together, once serve has built them.

**`Source`, not `Root`.** `Root` has `dir`, which isn't a connection, and the fd form is for embedders only. Keeping a separate union means neither type gains a variant the other must refuse.

**Only `root` is reserved.** Other names a guest's servers post, such as `factotum`, `plumb`, or `rio.glenda.123`, are the operator's to take: posting one means a guest server that tries to post the same name fails with "file exists", as a second post does on 9front. `root` is reserved because 9p-roots' plan line and namespace files depend on its meaning, even in runs without a 9P root.

**Refusing `--write=none`, not ignoring it.** As for 9p-roots, `none` promises nothing is written, and h9 can't keep that for a server the guest mounts. A run that wants a posted server read-only asks the server for it (`exportfs -R`, u9fs on a read-only tree), or binds `#O` over the mount.

**A heading of its own in the plan.** A `post` line in `namespace` would need newns to parse it, and a replayed namespace would then make connections, which namespace files otherwise only do for URLs. A separate heading keeps `namespace` a namespace and matches serve's `serve` heading.

**No dial-in mode.** A host server that connects to h9, rather than the other way round, would need h9 to listen, which is serve's business, and serve hands accepted connections to exportfs, not to `/srv`. An embedder with such a server can accept the connection itself and pass the fd.

## Compatibility

- **CLI:** new `--srv`. Exit 2 for misuse, including `--write=none` with `--srv`, and 125 for a connection that fails. Nothing changes without it.
- **`Machine.Options`:** new `srv` and `Machine.Srv`.
- **`--print`:** a `srv` heading, and caveats for writes, unencrypted entries, and entries reachable through `--serve`, when `--srv` is given. Plans without it are unchanged.
- **`/srv`:** has the entries at start. A guest server posting a name an entry took fails, as a duplicate post does on 9front.
- **Sandbox defaults:** unchanged. The network policy doesn't cover posted connections, as it doesn't cover the root's.
- **The root tree** and **`third_party/`:** unchanged. devsrv, devlfd, devip, devhstream, and devmnt are used as they are.
- **Browser host:** URL entries only, through the page's WebSocket. `tcp!` and `unix!` entries are exit 2, and `fd` sources aren't available.

## Security

- **What the guest newly reaches:** each posted server, under any attach name it accepts, as the machine's user. Nothing else is reachable through the connections, so a posted TCP server isn't a way to the network. Everything a posted server serves under any spec should be fit for the guest to see, as for a 9P root.
- **Who decides:** the operator, by naming each entry. There's no default entry and no way for the guest to add one; a guest's own posts go through its own connections and its own policy.
- **The network policy** isn't consulted for these connections, as it isn't for a root's. The plan lists every entry, so `--print` shows every server a run reaches outside `--net`.
- **What a server sees:** every operation on its mounts, and the attach `uname`, which is the machine's user and so the host user's name, as for roots.
- **Writes** reach the server unless it refuses them or an overlay covers the mount. The plan's caveat says so, and `--write=none` is refused.
- **The connections** are plain 9P. `tcp!` and `ws://` entries aren't encrypted or authenticated, and the plan says so for each.
- **Through `--serve`:** a client of a run that serves `/` can reach every posted server through `/srv`, as the machine's user, and so reach a host's unix socket server from the network. The plan says so per listener, and `--serve-root` below `/` closes it.
- **Credentials:** a token in a `ws` entry's query is on h9's command line, so it's in the host's process listing. `--print` and `--trace` elide it. An `@FILE` form is an open issue.
- **Isolation between machines:** each machine dials its own connections and posts them on its own board, and an `fd` source is owned by one machine. Two machines that should share a server each get their own connection to it.
- **Hostile servers:** devmnt is the same client that talks to 9P roots. A server can return anything in a file, and the guest runs what it chooses to from it, under its policy.

## Done when

Integration cases tagged `[host-srv]`. The servers are the 9p-roots test server, a second h9 running `exportfs` behind `aux/listen1 -t`, its unix-socket relay, and websocket-9p's test relay. The embedder case uses a socketpair and the stub 9P server the 9p-roots cases use.

- `test "a namespace file mounts a server posted from a unix socket [host-srv]"`
- `test "a guest program mounts a posted TCP server [host-srv]"`
- `test "a guest program mounts a posted ws:// server [host-srv]"`
- `test "one entry mounted with two specs uses one connection [host-srv]"`
- `test "a posted TCP server works under --net=disable [host-srv]"`
- `test "--net-allow doesn't see a posted connection [host-srv]"`
- `test "an unreachable entry exits 125 [host-srv]"`
- `test "an entry named root, a duplicate name, or a name with / exits 2 [host-srv]"`
- `test "--write=none with --srv exits 2 [host-srv]"`
- `test "/proc/n/ns prints a mount of a posted server as /srv/NAME [host-srv]"`
- `test "removing /srv/NAME leaves its mounts working [host-srv]"`
- `test "a server that hangs up fails the guest's reads [host-srv]"`
- `test "--print lists entries under srv and elides a URL's query [host-srv]"`
- `test "an embedder's socketpair is posted and mounted [host-srv]"`
- `test "a unix socket entry on Windows exits 125 [host-srv]"`, on Windows hosts only.

Once serve is built, tagged with both:

- `test "a --serve client mounts a posted server through /srv [host-srv, serve]"`
- `test "--print shows a caveat for posted servers under --serve-root / [host-srv, serve]"`

Demos:

- `h9 --srv fs=tcp!localhost!5640 --rc 'mkdir /tmp/n && mount /srv/fs /tmp/n && ls /tmp/n'` lists the served tree, with the server started as for 9p-roots.
- With serve: `h9 --serve unix!/tmp/a.sock`, then `h9 --srv a=unix!/tmp/a.sock --rc 'mkdir /tmp/a && mount /srv/a /tmp/a && ls /tmp/a/mnt/term'`.

## Implementation

1. Split 9p-roots' `connectRoot` in `src/machine.zig` into a connect (`tcp`, `unix`, `ws`, and `fd` through `lfdchan`) and a post to `#s/NAME`, with the root as their first caller and its errors unchanged.
2. `Machine.Srv` and `Machine.Options.srv`, and the loop after the root's mount that connects and posts each entry, with the errors and the fd's ownership.
3. `--srv` in `src/cli.zig` and `src/main.zig`: the forms, the names, and the usage errors.
4. The plan in `src/policy.zig`: the `srv` heading, the caveats, the `--write=none` conflict, and serve's caveat once serve exists. `--trace`'s connection lines.
5. The browser host: `createMachine`'s `srv`, with URL sources only.
6. The cases above. README: `--srv` and the demo. SPEC.md: the CLI flag table, `Machine.Options`, the boot sequence, and `/srv`'s paragraph. Set `status: implemented`.

## Open issues

- **Dial strings in namespace files.** [dotl](0022-dotl.md) shows `mount 'tcp!zerofs.example!5564' /n/z` in a namespace file, which needs namespace files to accept `tcp!` and `unix!` sources as websocket-9p made them accept URLs. Nothing proposes that yet. Either dotl's example becomes `--srv z=tcp!…` with `mount /srv/z /n/z`, or a proposal adds the sources with the late-conflict caveat in Rationale.
- **Checking at startup.** A `Tversion` before posting would turn a wrong dialect into exit 125 rather than a failed mount. Whether that's worth a round trip per entry, and whether it confuses servers that expect one `Tversion` per connection, is unsettled.
- **Host-side authentication.** [root-auth](root-auth.md)'s `p9any` on the host could authenticate entries too, but authentication happens per attach, and h9 doesn't attach. It would need h9 to answer the guest's `fauth` on the guest's behalf.
- **Secrets on the command line.** A `ws` entry's token is in the process listing. `--srv NAME=@FILE`, reading the address from a file as `--root-header @FILE` does, or per-entry headers, would keep it out.
- **Inherited fds from the CLI.** `--srv fs=fd!3` would let a supervisor or a shell's `3<>` pass a connected socket to the CLI as embedders pass one. It's small, but a new address form h9 doesn't otherwise have.
- **Reconnecting.** A posted connection that drops stays down for the run. dotl's `9P2000.L.Z` reconnects under devmnt; plain 9P can't.
