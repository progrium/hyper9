---
id: 13
slug: 9p-roots
title: 9P roots
status: implemented
created: 2026-11-03
authors: [progrium]
depends: [3, 8]
areas: [cli, kern, sandbox]
---

# Proposal: 9P roots

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

`--root` takes a 9P server as well as a host directory: a dial string (`tcp!fs.example!564`) or a unix socket (`unix!/run/fs.sock`, or the socket's path). h9 connects before the program starts and mounts the server through devmnt as the guest's `/`. Everything else in the namespace, the cwd, `/mnt/term`, `/dev`, and the rest, is bound over it as over a host tree. Programs are looked up and loaded through the kernel, so they run from the server unchanged.

## Background

This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's root filesystem list had three entries, of which only the first is built:

1. **Direct host tree:** a directory served through `#U`.
2. **9P mount:** `--root tcp!host!564` (or a unix socket path) dials and mounts through devmnt. Covers remote file servers and u9fs.
3. **Disk image:** [image-roots](0014-image-roots.md).

### h9 today

- **`--root DIR`** must name a host directory. `src/main.zig` resolves it with `realpath` and passes it in `Machine.Options.root`, a host path.
- **The plan** (`src/policy.zig`) binds `#U<root>` at `/`, read-only unless the root is a `--writable` path, and adds an access rule for it.
- **Lookup:** a program given as a guest path or a bare name is opened through the kernel along `$path`, and `exec` reads it through the kernel too. Nothing assumes the root is a host directory except the plan's first bind and its access rule.
- **devmnt** is drawterm's complete 9P client. The `--ns` replay already mounts with `kern.mount`, which wraps drawterm's `sysmount`.
- **Connections from the host:** devip (`#I`) dials TCP on every host. drawterm's devlfd wraps a host fd as a channel (`lfdchan`), which is how drawterm gives its kernel the host's stdio.

## Proposal

### `--root`

| Flag | Meaning |
| --- | --- |
| `--root DIR\|DIAL\|SOCKET` | The root tree: a host directory, a 9P server's dial string, or a unix socket. If omitted, use `$H9ROOT`, then the default install location |
| `--root-spec NAME` | The attach name (mount(1)'s `spec`) sent to a 9P root. Empty by default |
| `--root-user NAME` | The user name (`uname`) h9 sends in its attaches to a 9P root. The machine's user by default |

`--root`'s argument is read as:

- **`tcp!host!port`**, or `tcp!host`, which means port 564 (`9fs`): a TCP 9P server.
- **`unix!path`:** a unix-domain socket.
- **Anything else:** a host path. If it's a socket, it's a unix socket root. If it's a directory, it's a host tree, as now. Otherwise it's an error ("root X: not a directory or socket"), exit 125.

`$H9ROOT` takes the same forms.

### `Machine.Options`

`root` becomes a union:

```zig
pub const Root = union(enum) {
    /// A host directory, absolute and resolved, served through #U.
    dir: []const u8,
    /// A TCP 9P server: a dial string, `tcp!host!port`.
    tcp: []const u8,
    /// A unix-domain socket's host path.
    unix: []const u8,
};
root: ?Root = null,
/// The attach name for a 9P root.
root_spec: []const u8 = "",
/// The uname for h9's attaches to a 9P root; null means the machine's user.
root_user: ?[]const u8 = null,
```

### Connecting and mounting

The namespace builder does it first, in the machine's first Proc, before any other bind and before the device mask is set:

1. **Connect.** A TCP root is dialed through devip, by device path rather than through `/net`, so it works whether or not `#I` is bound or masked later. A unix socket root is connected by h9 on the host and wrapped as a channel with devlfd's `lfdchan`.
2. **Post** the connection's channel to the machine's root [devsrv](0008-devsrv.md) board as `root`, with `h9_srvpost`. The board holds it for the machine's life, so `--ns` can attach it again (below).
3. **Mount** `#s/root` at `/` with `MREPL`, with no auth fd and the spec from `--root-spec`. devmnt sends `Tversion` for `9P2000` and then `Tattach`. The attach `uname` is `--root-user` if given, otherwise the machine's user. devmnt takes `uname` from the calling process's user, so h9 sets the first Proc's user to `--root-user` for its attaches and restores it after.

Then the rest of the plan's binds run as they do over a host tree: `#c` and `#y` on `/dev`, `/$cputype/bin` and `/rc/bin` on `/bin`, the cwd at `/mnt/term/cwd` (falling back to `/mnt/term`), `#U/` after `/mnt/term` when needed, and the other devices.

**Failures** before the program runs are h9's: a refused connection, a failed `Tversion` or `Tattach`, or a server that wants authentication exit 125, with the server's error ("root tcp!fs!564: authentication required"). A server that answers `Tversion` with another dialect, such as `9P2000.L`, fails the same way until [dotl](0022-dotl.md) translates it. Once the program runs, a server that hangs up makes the guest's file operations fail as devmnt fails them ("i/o on hungup channel"), as on 9front. h9 doesn't reconnect.

**Unix sockets on Windows** aren't supported here: `unix!path`, or a socket path, on a Windows host exits 125 with "root unix!path: unix socket roots need a POSIX host". Windows has `AF_UNIX`, but a winsock handle doesn't go through devlfd's `ReadFile` and `WriteFile`. [websocket-9p](0021-websocket-9p.md)'s devhstream carries host-made connections without devlfd, and is where Windows support would come from.

**Authentication:** none in this proposal; [root-auth](root-auth.md) adds it. A 9P root is a server that answers `Tattach` without `Tauth`: u9fs with `-a none`, `exportfs` behind `aux/listen1 -t`, or a 9P server on a unix socket that relies on the socket's permissions.

### The policy and the plan

- **Writes** to a 9P root go to its server, which decides what's writable. h9 can't make devmnt read-only, so:
  - Under `--write=scope`, the default, the root isn't in the access rules, and the plan says "writes to the 9P root go to its server, which decides what can be written". Serve the tree read-only to keep it safe (`exportfs -R`, u9fs on a read-only directory).
  - `--write=none` with a 9P root is a usage error, exit 2: "--write=none can't be enforced on a 9P root".
  - Once [overlay](0011-overlay.md) is built, its default overlay goes over a 9P root as over a host tree, so writes land in memory and the server sees none.
- **The network policy** doesn't apply to the root's own connection. h9 makes it, not the guest, and the guest can't dial anything through it. `--net=disable` still masks `#I`.
- **Host paths** in the access rules (cwd, `--readable`, `--writable`, `--read-deny`, `/tmp`) are unchanged. devfs checks only `#U`, so none of them applies inside the 9P root.

`--print` shows the root as a `mount` of `#s/root`, and the access column says `9p`. A `--root-user` shows in the comment:

```text
$ h9 --print --root tcp!fs.example!564 ls
...
namespace:
  mount '#s/root' /                                       9p  # tcp!fs.example!564
  bind '#c' /dev
  bind -b '#y<id>' /dev
  ...
caveats:
  - writes to the 9P root go to its server, which decides what can be written
  - the 9P root's connection isn't encrypted
  ...
```

**In namespace files,** `mount '#s/root' old [spec]` makes a new attach on the machine's root connection, as mounting the same `/srv` file twice does on 9front. It's an ordinary mount of a posted channel, so newns needs nothing new: `--print` output replays with `--ns`, and a namespace file can put a second tree from the same server elsewhere (`mount '#s/root' /n/other other`). Once devsrv's `/srv` bind has run, `mount /srv/root …` means the same, from a namespace file or from the guest. The root mount itself names `#s/root` because it runs before `/srv` is bound.

### `--check`

`--check` runs `/bin/echo` from a 9P root as from a host tree, and reports the connection and attach errors above.

## Rationale

**Mount at `/`, not a union.** A 9P root is the whole tree, as a host root is. Binding everything else over it, rather than special-casing it, keeps one namespace builder and one plan format.

**Connecting from the host, before the mask.** The root belongs to the plan, not to the guest. Dialing it before the device mask is set means a run with `--net=disable` can still have a network root without the guest getting `#I`. It's what 9front's boot does: `bootrc` dials the file server, then the system runs on top of it.

**devip for TCP, devlfd for unix sockets.** devip already dials on every host, including Windows, where a winsock handle can't safely go through devlfd's `ReadFile` and `WriteFile`. devip has no unix sockets, but h9 can connect one on POSIX hosts and hand the fd to `lfdchan`, which is what devlfd is for.

**A socket by stat, a dial string by prefix.** An existing `--root DIR` keeps working, a socket path works the way the original design text said, and `unix!` and `tcp!` are 9front's own dial-string forms. A directory and a socket can't be confused.

**No authentication yet.** Authenticating needs keys on the host side of the mount, and a way to give them to h9 that `--print` and `--ns` can show without leaking. That's a design of its own, in [root-auth](root-auth.md). The servers people run for this, u9fs and `exportfs` on a trusted listener, don't need it, and this proposal's exit 125 for "authentication required" is what root-auth replaces.

**No reconnect.** devmnt can't re-establish fids on a new connection, so a reconnected root would look like a new server to every open file. drawterm's `aan.c` keeps a connection alive across network drops, but only between two ends that both speak aan, which file servers don't. A hangup fails operations, as it does on 9front.

**Refusing `--write=none`, not ignoring it.** `none` promises that nothing is written. h9 can't keep that promise for a server it doesn't control, so it says so rather than printing a plan that isn't true. A caveat is enough for `scope`, whose promise is about host paths.

**Posting the root to `/srv`, not a `<root>` placeholder.** A placeholder, like the console's `<id>`, would need its own syntax in newns and in every proposal that makes roots ([websocket-9p](0021-websocket-9p.md), [dotl](0022-dotl.md)). Posting the channel makes it a name 9front already has: `#s/root` replays with `--ns` unchanged, re-attaches the open connection rather than dialing again, and lets a guest mount another tree from the same server the way it would on 9front. The cost is the dependency on devsrv, which websocket-9p and dotl have anyway. Other host-made connections in `/srv` are [host-srv](host-srv.md)'s.

**`--root-user`, not always the host user or always `none`.** The machine's user is the right default: it's the guest's `$user`, and u9fs and exportfs map permissions by it. But it tells the server who's on the host, so a run that doesn't want that, or a server that expects a different name, can set it. Sending `none` by default would break servers that check the name.

**Speed is measured, not designed for.** A 9P root costs a round trip per walk, open, and read, and drawterm's devmnt has no cache. Done when measures it. If a unix socket root is more than about 3× slower than a host root on those workloads, the remedy is a read-only cache for roots served with `exportfs -R`, keyed by qid version, in project code rather than in devmnt, and it's a proposal of its own. The numbers go under Updates.

**Depending on semaphores.** The test server is 9front's `exportfs`, whose procs share qlocks, and contended qlocks park on `rendezvous`. Without [semaphores](0003-semaphores.md) the cases below would fail at random, not because of anything here. [devsrv](0008-devsrv.md) holds the root's channel.

## Compatibility

- **`--root` and `$H9ROOT`** accept new forms. Every existing directory argument means what it did.
- **`--root-spec`** and **`--root-user`** are new.
- **`Machine.Options.root`** changes type from a host path to `Root`. Embedders write `.root = .{ .dir = path }`. `root_spec` and `root_user` are new.
- **`--print`** gains the `mount '#s/root'` line and the `9p` access kind for 9P roots. Plans for host roots are unchanged.
- **`/srv`** has a `root` entry when the root is a 9P server, and not otherwise.
- **Exit codes:** connection and attach failures, a server that isn't `9P2000`, and a unix socket root on Windows are 125. `--write=none` with a 9P root is 2.
- **Sandbox defaults** for host roots are unchanged.
- **Vendored tree:** unchanged. devip, devmnt, and devlfd are used as they are.

## Security

- **What the guest newly reaches:** the files the server serves, as `/`. It can't reach the server's network, or anything else, through the connection.
- **The guest can attach other trees** from the root's server through `/srv/root`, with any spec the server accepts, as it could if it dialed the server itself. Everything the server serves under any attach name should be fit for the guest to see.
- **What the server sees:** every file operation the guest makes on the root, and the attach `uname`: `--root-user`, or the machine's user, which is the host user's name. Attaches the guest makes itself through `/srv/root` send the machine's user. A run trusts its 9P root as it trusts a host root: it runs the server's binaries, inside the same sandbox.
- **Writes** reach the server unless the server refuses them or [overlay](0011-overlay.md) covers the root; the plan's caveat says so, and `--write=none` is refused.
- **The connection** is plain 9P, not encrypted or authenticated, so a TCP root should be on a trusted network or a tunnel. The plan says so.
- **Isolation between machines:** each machine dials its own connection, and posts it on its own `/srv` board.

## Done when

Integration cases tagged `[9p-roots]`. The server is a second h9 serving the test root tree with `aux/listen1 -t tcp!127.0.0.1!PORT /bin/exportfs -R -r /`, so no host 9P server is needed:

- `test "a TCP 9P root runs /bin/ls [9p-roots]"`
- `test "a unix socket 9P root runs /bin/ls [9p-roots]"`: a unix socket that the test relays to the TCP server.
- `test "rc pipelines and exec run from a 9P root [9p-roots]"`
- `test "the host cwd is bound over a 9P root [9p-roots]"`
- `test "a 9P root works under --net=disable [9p-roots]"`
- `test "--root-spec is sent as the attach name [9p-roots]"`
- `test "--root-user is sent as the attach uname [9p-roots]"`
- `test "the guest mounts /srv/root at a second path [9p-roots]"`
- `test "an unreachable 9P root exits 125 [9p-roots]"`
- `test "a 9P root that wants authentication exits 125 [9p-roots]"`
- `test "--write=none with a 9P root is a usage error [9p-roots]"`
- `test "a unix socket root on Windows exits 125 [9p-roots]"`, on Windows hosts only.
- `test "--print shows a 9P root, and its output replays with --ns [9p-roots]"`
- `test "--check runs /bin/echo from a 9P root [9p-roots]"`

Demo: `h9 --root tcp!localhost!5640 ls /` lists the served tree, with the server started as above.

Measured: the same workloads (`ls -l /bin`, an rc pipeline, and `mk` on a small tree) timed over a host root, a loopback TCP root, and a unix socket root, with the numbers in a dated note under Updates.

## Implementation

1. `Machine.Options.Root`, `root_spec`, and `root_user`, with `dir` behaving exactly as `root` did. `src/main.zig` and `src/tools.zig` updated.
2. TCP roots: the dial, the post to `#s/root`, and the mount in `src/machine.zig`'s namespace builder, the errors, and `--root`, `--root-spec`, and `--root-user` in `src/cli.zig` and `src/main.zig`. The TCP cases pass.
3. Unix socket roots on POSIX hosts: the host connect and `lfdchan`, and the error on Windows.
4. The plan: the `mount '#s/root'` line, `9p` access, the caveats, and the `--write=none` conflict in `src/policy.zig`.
5. The speed measurement, recorded under Updates.
6. README's `--root` notes. DESIGN.md: the Decisions table's root row, the root filesystem paragraph, the boot sequence, the CLI flag table, and `Machine.Options`. Set `status: implemented`.

## Updates

- 2026-11-06: Refinements made while implementing it:
  - The connection is posted the way a guest posts one, by creating `#s/root` (mode 0666) and writing the connection's fd number into it, rather than with `h9_srvpost`, which needs the board's chan. The effect is the same.
  - A TCP root is dialed by writing the dial string to `#I/cs` and trying each translation through `#I/tcp/clone`, so `tcp!host!port` takes names as well as addresses. The machine's plan is cleared on the first Proc's thread for the dial, so neither the network policy nor `--net-allow` sees it.
  - `--print` writes the spec of the root's mount even when it's empty, as `mount '#s/root' / ''`, so newns can tell a spec from the `9p` column: a mount's access column is its fourth word. A replayed root mount is an ordinary mount from the namespace file, so it sends the machine's user, not `--root-user`.
  - The private `/tmp` over a 9P root is a bare `#O` over the root's own `/tmp`, printed as `bind -c '#O' /tmp` with no host path, as in a namespace file.
  - The unix socket connect is `h9_unixdial` in `src/kern/rootdial.c`, which also sets and reads the calling process's user for `--root-user`. On Windows it fails with "unix socket roots need a POSIX host".
  - `--root-user` is cut to the kernel's 27-byte user names.
  - The `--root-spec` and `--root-user` cases, and the authentication case, use a stub server in the test that records the `Tattach` and refuses it, since `exportfs` ignores the attach name and doesn't use `Tauth`.
- 2026-11-06: Measured on an Apple Silicon Mac with HVF, as seconds per run, the mean of 20 runs of each (the script is in the PR). The server is a second h9 running `exportfs -R` behind `aux/listen1 -t`; the unix socket is relayed to it by socat, so that row includes the relay's hop as well.

  | Root | `ls -l /bin` | `ls -l /bin \| sort \| wc -l` | `mk` (7c and 7l of a small program) |
  | --- | --- | --- | --- |
  | Host tree | 0.018 | 0.025 | 0.022 |
  | `tcp!127.0.0.1!5640` | 0.029 (1.6×) | 0.042 (1.7×) | 0.053 (2.4×) |
  | Unix socket | 0.030 (1.7×) | 0.045 (1.8×) | 0.057 (2.6×) |

  The unix socket root stays under the 3× bound in Rationale, so no root cache is proposed for now. `mk` is the closest to it, because the compiler and linker read many headers and libraries through devmnt.
