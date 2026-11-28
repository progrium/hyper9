# The sandbox

This describes, as built, h9's security stance and the sandbox policy: what a guest can reach on the host, and how the policy is compiled, checked, and printed. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Security stance](#security-stance)
- [Sandbox policy](#sandbox-policy)
  - [The machine's host](#the-machines-host)
  - [Device hooks](#device-hooks)
  - [Network rules](#network-rules)
    - [Route probes](#route-probes)
  - [The machine's resolver](#the-machines-resolver)
  - [Access rules](#access-rules)
  - [Path resolution](#path-resolution)
  - [Files beneath a handle](#files-beneath-a-handle)
  - [Handle names in the namespace](#handle-names-in-the-namespace)
  - [Contained trees](#contained-trees)
  - [Linux symlinks](#linux-symlinks)
  - [Default profile](#default-profile)
  - [Discarded root changes](#discarded-root-changes)
  - [The root overlay's cost](#the-root-overlays-cost)
  - [Plans](#plans)
  - [Pinned roots](#pinned-roots)
  - [Plan output](#plan-output)
  - [Ephemeral writes](#ephemeral-writes)
  - [Up layers](#up-layers)
  - [Examples](#examples)

## Security stance

**Security stance.** The hypervisor isolates guest memory and the CPU, and every guest syscall is served by drawterm's kernel rather than the host's, so the guest never reaches host syscalls, ioctls, or the host environment directly. The namespace decides what a guest can reach on the host. Identity: hostowner is the host user's name; devfs maps the host's file ownership onto Plan 9 user strings.

## Sandbox policy

Sandboxing is a `Policy` in `Machine.Options`: a set of capabilities, host paths, network rules, and limits. The capability model follows [isobox](https://github.com/can1357/isobox): named capabilities, profiles that set defaults, explicit flags that override them, and a printable plan with caveats. Unlike isobox, enforcement lives in the shared kernel, so the capability set is the same on every engine; there's no per-host intersection to compute.

| Capability | Mechanism |
| --- | --- |
| `env.scrub` | The host environment is never imported |
| `kernel.isolation` | Guest syscalls are served by drawterm's kernel |
| `ipc.restrict` | Host sockets are reachable only through `#U` or `#I`, which the policy controls |
| `fs.read.scope`, `fs.write.scope` | The namespace is an allowlist: only listed host paths are bound from `#U`, each read-only or read-write |
| `fs.write.ephemeral` | Each path `scope` would make writable is a copy-on-write `#O` overlay over its `#U` tree instead; changes live in memory and vanish at exit |
| `fs.write.overlay` | A copy-on-write `#O` overlay over the root, whatever kind of root it is, so writes to it succeed in memory and vanish at exit; under `--write=overlay` (the default) and `--write=ephemeral` |
| `fs.read.deny` | Unbound paths don't exist; denied paths inside a bound tree are filtered in devfs |
| `net.disable` | `#I` and `#ℏ` are masked in the init Pgrp (drawterm's `devmasked`), so the guest can't re-attach them, and `/net/ws` isn't bound |
| `net.outbound` | devip refuses `announce`, TCP and UDP, so the guest can dial out but not serve; `/net/ws` only connects |
| `net.allow` | devip checks each `connect` against dial-string patterns (`tcp!10.0.0.0/8!564`, `tcp!*.example.com!443`), and devip's `cs` refuses to resolve names no pattern covers; an egress allowlist isobox can't offer |
| `res.memory` | A cap on the guest-physical page allocator; exact, not a watchdog |
| `proc.children` | `#μ` is bound on `/dev` and left out of the device mask, so the machine can start child machines; under `--children`, and never under `tight`. A child shares the machine's kernel ([child-machines](../design/child-machines.md)) |
| `proc.timeout` | A machine deadline: a `hangup` note to every process, then a hard teardown after a 2 s grace period |
| `res.pids`, `res.cpu` | A cap on live processes in `rfork`; a cap on vCPUs running guest code at once |

### The machine's host

A machine reaches outside only through its host ([host-handles](../design/host-handles.md), `src/host/host.zig`): a table of handles, each an interface of a context and a function table, as `std.mem.Allocator` is. A handle that's null is a capability the machine doesn't have, so `Host{}` reaches nothing.

| Handle | Gives | Native | Web |
| --- | --- | --- | --- |
| `dirs` | The host trees, by name (`root`, `cwd`, and `d1` on), each read-only or read-write, with its read-deny paths | A directory fd or `HANDLE`, opened when the machine is made | A WASI preopen, described and not opened |
| `dial` | Outbound connections, and the names that may be resolved for them | Sockets (`src/host/net.zig`) | The checks; the guest's devip has no sockets there |
| `listen` | Listening addresses | Sockets | None: a page can't listen |
| `clock` | Wall and monotonic time | The OS's | WASI's, which is JavaScript's |
| `console` | The terminal | The run's `Machine.Stdio` | The page's terminal |
| `random` | Entropy | The machine's `std.Io` | WASI's, which is `crypto.getRandomValues` |
| `window` | The `--gfx` window, or the headless screen | drawterm's GUI backend | The canvas |
| `spawn` | Host commands ([host-cmd](../design/host-cmd.md)) | None yet: `#C` is masked | None |

`Machine.init` builds the host the compiled plan describes (`src/host/planned.zig`), on every host: its handles ask the plan, so what's allowed is the plan's, and `--net=disable` is no `dial` and no `listen`. An embedder can give its own in `Machine.Options.host`: the policy is still compiled beside it, and devfs still checks the plan's verdicts, so a file needs both a handle and the plan's leave, while devip asks the embedder's dialer and listener alone. The embedder's directory handles stay its own to close, and its console, when it has one, replaces `Options.stdio`'s. With `.host = .{}`, a 9front root mounted from the host is unreachable (`test "a kernel with an empty Host can reach nothing outside [host-handles]"`). A directory handle can be a tree with no host directory, `Dir.tree` (a `host.Tree`, such as a `host.MemTree` built from a list of files): namec walks a `#U` path such a handle holds on the tree device, `#ū<name>`, instead (`src/host/devtree.zig`), which serves it read-only, so a mount of the handle's path reaches it, a root's under an overlay among them (`test "an embedder's in-memory dirs handle serves a root [host-handles]"`). The plan's rules still name the tree by its path, which nothing on the host need hold; the device asks the plan's verdict on that path at attach, and `#ū` is masked wherever `#U` is. A machine whose host has no clock, and a kernel thread with no machine, read the OS's clock.

### Device hooks

The policy lives in Zig. The host's devices, devfs and devip (`src/host/`, see [spec/kernel.md](kernel.md), "The host's devices"), call it through leaf functions, which return a status and never raise.

devfs, on POSIX and on Windows, calls `h9_fs_check(path, op)` (in `src/host/fscheck.c`) before each walk, open, create, remove, wstat, and directory entry. It resolves the host path and asks the Zig leaf `h9_policy_check` for a verdict: allowed, hidden (the walk fails, or the entry is left out of the listing) or read-only ("permission denied").

devip calls `h9_net_check(op, proto, addr, port)` (declared in `src/kern/netcheck.h`) when a ctl file's `connect` or `announce` is parsed, before a port is bound or the host is dialed, and raises "permission denied" on a refusal. It asks the machine's host ([host-handles](../design/host-handles.md), `src/host/host.zig`): a `connect` its dialer (`Dial.allows`, then `Dial.probe`), an `announce` its listener (`Listen.allows`), and a host without one refuses. The host a plan describes (`src/host/planned.zig`) answers with the plan's verdicts, so what's allowed is unchanged.

Its `cs` calls `h9_net_lookup(proto, name, port)` before the host's resolver, raising "no translation for host found" for a name no pattern covers, and `h9_net_resolved` after it.

Its connect calls `h9_net_redirect(proto, addr, &port, &sfd, opts)` right after `h9_net_check`, which may replace the address and port it dials with the machine's resolver's ([linux-dns](../design/linux-dns.md), under [The machine's resolver](#the-machines-resolver)), and raises "permission denied" when it would and can't. It's the one hook in devip for the resolver; the rest, in `src/kern/netcheck.zig`, binds the conversation's host socket on the loopback first (making it if there's none) and tells the resolver its host port, through the Zig leaves `h9_dns_target` and `h9_dns_register`. For a UDP connect that isn't redirected, it also marks the conversation's host socket probe-only or not (see [Route probes](#route-probes)), making the socket first for a probe; devip's write to a conversation's `data` calls `h9_net_send(sfd)` before it sends, and raises "permission denied" on a probe-only one. That call is the other hook in devip's send path; `h9so_close` forgets a socket's mark before it closes it.

The machine's compiled plan is set per host thread, because each guest process runs on its own thread. The leaves return an int and never raise kernel errors themselves.

### Network rules

Under `--net=outbound` (the default profile's setting) `announce` is refused; `--net=enable` allows it.

Without `--net-allow`, a `connect` to link-local addresses (169.254.0.0/16, fe80::/10) or to the cloud metadata endpoints outside link-local (AWS's IPv6 `fd00:ec2::254` and Alibaba Cloud's `100.100.100.200`) is refused in both modes (`refusedByDefault` in `src/policy.zig`), which keeps the metadata services out of reach, and everything else is allowed.

With patterns, the patterns are the whole policy: a `connect` must match one, by protocol (`tcp`, `udp`, or `net`/`*`), address (an address, a CIDR range, or `*`) and port (a number, a range, or `*`). IPv4 is matched as IPv4, however devip spelled it.

A name pattern (`api.example.com`, or `*.example.com` for one or more labels) can't be checked at `connect`, whose message is numeric, so `cs` resolves only names a pattern covers and records what each returned in the machine's resolved-name table (the 1024 most recent entries). A later `connect` to a recorded address is allowed if its name matches a name pattern with that protocol and port.

A resolved-name entry from the machine's resolver has no protocol or port, so it takes the connect's, which the name patterns then decide: a name allowed as `tcp!api.example.com!443` allows TCP port 443 to its addresses only, whichever lookup recorded them.

#### Route probes

getaddrinfo, musl's and glibc's alike, ranks the addresses it got by RFC 6724: it connects a UDP socket to each, which sends nothing, and reads the source address with `getsockname`, so an address the host has no route to ranks last. Its probe's port is the service's, so a TCP name pattern doesn't cover it. A UDP `connect` to an address the resolved-name table recorded for a name some name pattern covers, with any protocol and port, is therefore allowed as a probe (`Plan.netProbe`, and `NameTable.recorded`): `h9_net_check` returns 1 for it rather than 0, and the connect is made on the host, so its result (success, or ENETUNREACH for a family with no route) and its source address are the host's, as with the network open. Such a conversation is probe-only: every send on it, a write to `data`, or a Linux `send`, `write`, or `sendto` to any address, fails with "permission denied" (EACCES), so nothing reaches the address that the allowlist didn't allow. Its host socket is marked in a table in `src/kern/netcheck.zig`, one for the process since host sockets are, set or cleared at each connect, so a conversation that connects again to an address the allowlist allows for UDP sends as any other. A UDP connect to an address that isn't recorded, and a TCP connect, are checked as before, and a `sendto`'s address must be allowed outright, not as a probe.

A `/net/ws` `connect` is checked as a TCP dial to the URL's host and port: a name goes through the same lookup check and resolved-name table, and each address it resolves to through the connect check.

Connections h9 makes itself (a root, a namespace-file mount) are outside the policy, and the guest can't reach them by name. `--net-allow` with `--net=disable`, or a bad pattern, is exit 2.

### The machine's resolver

A machine *resolves for the guest* when its plan has a name pattern (`Plan.resolves`) and a network ([linux-dns](../design/linux-dns.md)), on any host but the web one, whose network is WebSockets. Its resolver (`src/resolver.zig`) belongs to the machine, as its resolved-name table does: each run starts one, a UDP socket and a TCP listener on 127.0.0.1 on ports the host picks and a thread that answers them, and stops it when the run ends. It's kept in the machine's arena, so a stuck process finds its ports closed rather than its memory freed. The resolver's host sockets come from the machine's host ([host-handles](../design/host-handles.md)): its listener's `Listen.bind` opens the two it listens on, and its dialer's `Dial.connect` the ones it forwards each query with. They're h9's own, so the listener makes them under `--net=outbound` too, where it refuses every guest address, and the dialer doesn't check them against the allowlist. The planned host makes them with `src/host/net.zig`, whose calls are written once, over the host's socket calls: POSIX sockets, made close-on-exec and non-blocking with `fcntl` after `socket`, and waited for with `poll`, or on Windows Winsock `SOCKET`s, made with `WSA_FLAG_NO_HANDLE_INHERIT`, made non-blocking with `ioctlsocket` (`FIONBIO`), and waited for with `select`. On Windows the listeners also take `SO_EXCLUSIVEADDRUSE`, so no other process can bind their ports, and the UDP one has `SIO_UDP_CONNRESET` off, so a reply to a guest port that has closed doesn't fail its next read.

- **Redirecting port 53.** `h9_net_check` allows a connect to port 53, TCP or UDP, on any address, and `h9_net_redirect` then dials the resolver instead; a Linux `sendto` to port 53 is redirected the same way (`h9_net_redirectto`, from `src/kern/linuxnet.zig`). Without a resolver (one that failed to start) the redirect fails, and so does the connect. The conversation's host socket is bound on the loopback before it's dialled (a socket that isn't bound yet has port 0, which on Windows is a failed `getsockname`), and its host port is registered with the resolver along with the address the guest dialled, so a `recvfrom` on it gives that address as the source, and so does `getpeername`. devip's `remote` file shows the resolver's address.
- **Answering.** A message that isn't a query with one question gets `FORMERR`. The question's name, lowercased and without a trailing dot, must match a name pattern for any protocol and port, as `h9_net_lookup`'s rule has it; otherwise it gets `REFUSED` and isn't sent anywhere. An allowed query goes as it came to `Machine.Options.nameservers`, in order and over the transport it came on, each given its share of 5 seconds, and the first answer with the query's id comes back; with none, `SERVFAIL`. Every query type is forwarded, and a truncated UDP answer is passed on as it is, for the guest's retry over TCP.
- **Recording.** Before an answer goes back, its answer section's `A` and `AAAA` records whose owner is the question's name, or a name its `CNAME` records lead to from it (at most 16), are recorded in the resolved-name table under the question's name. Only answers to a host port devip registered are recorded, so another host process that finds the resolver's sockets can't add entries. Names and records are parsed with bounds checks and at most 32 compression pointers a name, and a message that doesn't parse is passed on, recording what came before the fault.
- **The DNS servers' own rule.** Under such a machine, port 53 never reaches a DNS server directly, so the link-local exception for the host's servers, and the need for patterns to cover them, don't apply, and an address pattern that covers a server (`udp!10.0.0.53!53`) doesn't take its queries out of the resolver: every one is checked and recorded. DNS over TLS or HTTPS isn't seen, so it's refused unless a pattern covers the server.

Each nameserver may give a port, `ADDR!PORT`. The CLI passes the host's servers on port 53 whenever there's an allowlist, and `#Letc`'s `resolv.conf` names the address alone. The plan's caveats say "DNS queries to port 53 go to h9's resolver, which forwards names the allowlist covers to the host's DNS servers".

### Access rules

The plan's rules are the root, the cwd, each `--readable` and `--writable` path, and each `--read-deny` path, all as resolved host paths. Overlaid paths (`eph`) are read-only rules, since the overlay never writes its lower tree. An `up` `--dir` is a read-write rule, as `rw` is, and the trees beneath it are only read. A deny rule covering a path wins. Otherwise the longest allow rule covering the path decides between read-only and read-write. Ancestors of allowed paths can be walked and listed but not changed, so `/mnt/term/<path>` works when the host's `/` is unioned after the tree's `/mnt/term`. Anything else is hidden. Bind-level read-only (no `MCREATE`) is a second, coarser check.

### Path resolution

For a 9front program, devfs on POSIX hosts follows symlinks with `stat`, so a symlink inside a bound tree can point anywhere on the host. A Linux program's walks don't follow them ([Linux symlinks](#linux-symlinks)).

Every devfs path is resolved and the resolved path is checked against the access rules, on every host. On Linux a clean absolute path is first looked up with one `openat2` with `RESOLVE_NO_SYMLINKS`; if it holds no link it is already canonical, and otherwise it's resolved by an `O_PATH` open and its `/proc/self/fd` name, so a check costs a constant number of calls however deep the path is (`realpath` reads every element with a `readlink`, so a walk down a tree cost the square of its depth). Linux without `openat2` or `/proc`, macOS, and the web host use `realpath`, and Windows the final path of an opened handle, which follows symlinks and junctions and refuses UNC and device paths.

Create, remove, and rename act on the name rather than a link's target, so an existing entry is checked by its own canonical name without following it. On macOS that's `F_GETPATH` on an `O_SYMLINK` open, and on Windows the final path of a reparse-point open, so another case, an 8.3 short name, or a trailing dot can't dodge a rule on a case-insensitive file system. A new name is appended to its resolved parent. A create over an existing symlink also checks the link's target for writing.

Renaming a directory that has any rule strictly beneath it is refused ("permission denied"), because it would move those paths out from under their rules. The check and the host call aren't atomic, so a host process renaming paths at the same time can race it; the plan reports that, and hardlinks under writable paths, as caveats.

### Files beneath a handle

Each tree the plan allows is a directory handle ([host-handles](../design/host-handles.md)), opened when the machine is made (`src/host/dirs.zig`): a directory fd (`O_PATH` on Linux) or on Windows a `HANDLE`, or for a tree that's one file its directory's and its name. devfs still names host files by their resolved paths, and its checks are as above, but every host open it makes (and on POSIX hosts every `stat`, `lstat`, and `readlink`) goes through `src/host/dirs.c`, which finds the deepest handle whose path holds the file and opens it relative to that handle, so the host keeps the result inside the tree:

- **Linux.** One `openat2` with `RESOLVE_BENEATH` and `RESOLVE_NO_MAGICLINKS` (`RESOLVE_IN_ROOT` for a contained tree, and `RESOLVE_NO_SYMLINKS` too for a Linux process's walk), retried on `EAGAIN`, which a rename racing the lookup gives. A `stat` is an `O_PATH` open and `fstat`.
- **macOS.** One `openat` with `O_RESOLVE_BENEATH` (and `O_NOFOLLOW_ANY` for a Linux process's walk), and a `stat` is one `fstatat` with `AT_RESOLVE_BENEATH`, which opens nothing. The kernel follows a relative link that stays beneath the handle and refuses an absolute one, or a `..` above the top, with `ENOTCAPABLE`, which is an escape. macOS has no `RESOLVE_IN_ROOT`, so a contained tree's open or `stat` that the kernel refuses takes the walk below. A kernel without `O_RESOLVE_BENEATH` (before macOS 15), found by a probe on first use, takes the walk for everything. The walk is slow there: each directory it opens costs about 5 µs.
- **The BSDs, and Linux without `openat2`.** A walk of one name at a time from the handle: each name is looked at with `fstatat` (`AT_SYMLINK_NOFOLLOW`) and opened with `O_NOFOLLOW|O_DIRECTORY`, so a link swapped in fails the open; a link is read with `readlinkat` and walked in place if relative, and an absolute one, or a `..` above the top, is an escape (for a contained tree, back to the top). At most 40 links.
- **Windows.** `NtCreateFile` relative to the handle, a name at a time, each with `FILE_OPEN_REPARSE_POINT`; a symbolic link or junction met on the way (a name surrogate reparse point) is an escape. Opens, creates, and directory creation go this way, and so do deletes and renames, which open the entry itself (a link, not its target) and act on that handle: the delete disposition, and `NtSetInformationFile`'s rename with a bare name, within the entry's own directory. A symbolic link or FIFO is made as an empty entry this way and then given its reparse point on the handle: `IO_REPARSE_TAG_SYMLINK`, with the target as written (`\` for `/`, marked relative), which needs `SeCreateSymbolicLinkPrivilege` (h9 turns it on in its token where the token holds it, as an administrator's does), or WSL's `IO_REPARSE_TAG_LX_FIFO`. Without the privilege a symbolic link is WSL's instead, `IO_REPARSE_TAG_LX_SYMLINK` with the target as UTF-8, which needs none; h9 and WSL follow it, and Windows' own programs can't open through it. Attributes and `FindFirstFile` are still by path, with the checks above.
- **The web host.** No handles are opened: each tree is a WASI preopen, and wasi-libc resolves every path beneath the preopen that holds it, so the runtime keeps the result inside it. devfs opens by path there, with the checks above.

A 9front program's walks follow links anywhere ([Path resolution](#path-resolution)), so an open whose links leave its handle is made again by the path it resolves to (its `/proc/self/fd` name, `F_GETPATH`, or on Windows its final path), beneath the handle that holds that, if one does, with no link followed; otherwise it fails as a hidden file does. A path no handle holds is an ancestor of one, listed for `/mnt/term/<path>`, or hidden: only directories are opened there, read-only, by path, and devfs's checks of what it opened decide. A thread with no host (a kernel thread, or a plan built without one) opens by path. `test "a symlink swapped in mid-walk can't escape a handle [host-handles]"` swaps a directory and a link to outside the tree under each kind of open.

### Handle names in the namespace

`/proc/n/ns` names a host tree by its handle ([host-handles](../design/host-handles.md)), not its host path: `#U<name>` for a handle's top and `#U<name>/<path>` beneath it, so the cwd is `bind -c '#Ucwd' /mnt/term/cwd` and another tree `bind '#Ud1' <target>`. `chan.nsname` rewrites each `#U` path that `/proc/n/ns` and `#O`'s union lines print, asking the machine's host which handle holds it (`h9_host_nsname`, the deepest). The namespace's own names are unchanged: a tree's channels are still named by resolved host paths, which devfs opens and checks. A walk of `#U<name>` goes the other way (`h9_host_nspath`), so a `bind`, a `mount`, and `--ns` take the names `/proc/n/ns` prints, and its output replays in a machine with the same handles (`test "--ns replays /proc/n/ns output in a machine with the same handles [host-handles]"`). A path no handle holds, an ancestor that `/mnt/term` lists, is printed as before. The guest paths of `--readable` and `--writable` trees outside the cwd are still `/mnt/term/<host path>`, as drawterm's are.

### Contained trees

A bind from `#U!c/path` ([symlinks-in-root](../design/epoch-0/symlinks-in-root.md)) is *contained*: devfs resolves its links itself, inside the tree, as `openat2`'s `RESOLVE_IN_ROOT` does.

The tree's top is where namec's walk from the `#U!c` attach ends (`h9_fs_anchor`, called from `namec` in `src/kern/chan.zig`), canonicalised.

Each later walk looks names up one at a time with `lstat` (`h9_fs_resolvein` in `src/host/fscheck.c`; on Windows `h9_fs_resolveinw`, which reads symlinks, junctions, and WSL's links with `FSCTL_GET_REPARSE_POINT` and refuses other reparse points and UNC targets): a link's target is read, an absolute one starts again at the top (on Windows, with its drive dropped), a relative one from the link's directory, `..` at the top stays there, and more than 40 links in one walk is "too many symbolic links".

The resolved path, which holds no links, is checked against the access rules as any other path is, so `--read-deny` and partly allowed trees still apply, and kept on the chan with the link's own path beside it: stat shows the link's name, remove and rename act on the link, and open, read, and wstat on its target.

A listing shows each link with its target's `Dir` and leaves out a link whose target is missing or loops, since walking it fails.

`h9_fs_readlink` (and `h9_readlink` by guest path, `src/kern/syswide.zig`, through the device's readlink operation, design/file-interface.md; `kern.readlink`) gives a link's target as written, for the Linux ABI; Plan 9 programs never see links.

These rules are a 9front program's. For a Linux program the boundary is the process's root instead of the tree's top ([Linux symlinks](#linux-symlinks)).

An uncontained `#U` attach is unchanged. `--dir PATH:DST:contained`, and every `--dir` on `#L`, makes that mount's bind contained; other binds, including writable paths inside it, stay uncontained. `--print` shows it as `bind '#U!c/path' DST`, which replays with `--ns` where `#U` isn't masked. Any other `#U` attach spec is "bad attach specifier".

### Linux symlinks

A Linux process's walks ([linux-symlinks](../design/epoch-0/linux-symlinks.md)) stop at a link instead of following it, and the kernel's walk follows it from the process's root, the Linux view, so a link resolves through the same mounts, binds, and `#L` layers as the path the program would get by writing its target out. A 9front process's walks are unchanged. A process walks this way when its root is the Linux view (`h9_fs_linkwalk`, `src/kern/linux.zig`).

A device's walk stops at the first link it meets: the link is the last qid of its `Walkqid`, with `H9_QTSYMLINK` (`0x02`, 9P2000.u's and .L's qid bit) in its type, and the names after it aren't walked. The link `stat`s with `H9_DMSYMLINK` (9P2000.u's `0x02000000`) and its own size and times, and a directory read lists it so, with or without a target. devfs (posix and win32, contained or not), the overlay's `Nlink` nodes and its lower tree's links, a union's members, and a 9P2000.L mount ([ninep.md](ninep.md)) stop this way. `namec` refuses to open a link that a Linux open didn't follow, on any device.

devfs looks each name up with `lstat` (on Windows, `FindFirstFile`, whose entry for a symbolic link or junction isn't followed) and checks it against the access rules by its own path (`h9_fs_checkname`) rather than its `realpath`. A walk's path holds no links, from a canonical start (the first such walk from a chan `realpath`s it), so `..` is its parent, and it stops at a contained tree's top. An open of the walked path doesn't follow a link that appeared since: on Linux it's an `openat2` with `RESOLVE_NO_SYMLINKS`, on macOS an `open` with `O_NOFOLLOW_ANY`, elsewhere (and on Linux kernels without `openat2`) a chain of `openat`s with `O_NOFOLLOW` from `/`, and on Windows an open of the reparse point itself, refused if it is one. A link swapped in after the walk fails the open ("too many symbolic links") instead of being followed by the host, and a create doesn't follow a link left in its name. Those opens are made beneath the handle that holds the path ([Files beneath a handle](#files-beneath-a-handle)), with no link followed. The web host, with no `/` to start from, refuses a link only as the last name.

`walk()` in `src/kern/chan.zig` follows a link when a walk stopped at one with names left, or at the last name of a lookup that follows links (`followlink`): it reads the target (the link's device's readlink operation, `dev.readlink` in `src/kern/dev.zig`, which an overlay passes down to the tree that holds it) and walks it, an absolute target from the process's root and a relative one from the link's directory as the walk reached it, then the rest of the path. A mount point before the link is crossed first. The result's name is the target's, so `..` after a link is the target's parent, and `getcwd` after a `chdir` through one is the target's path. More than 40 links in one lookup is "too many symbolic links". A lookup follows a link in its last name unless it's a remove or the call says not to (`h9_fs_nofollow`, per process): `lstat`, `readlink`, `rename`'s old name, and `O_NOFOLLOW`. `namec`'s `h9_fs_anchor` call, after the walk, is unchanged.

A 9P2000.L mount follows its own links, from its attach root, only for a 9front process ([ninep.md](ninep.md)).

### Default profile

With no sandbox flags the guest can work in the host cwd and nothing else:

| Area | Default |
| --- | --- |
| Root tree (`/`) | Read-only underneath, with an ephemeral overlay: writes succeed in memory, count against `--memory`, and vanish at exit, for a host tree, a 9P root, and the built-in root alike. `$home` (`/usr/$user`) is made in the overlay if the root lacks it. Installing into the root needs `--writable "$H9ROOT"`; `--write=scope` makes it read-only, and a 9P root then as writable as its server allows |
| Host cwd (`/mnt/term/cwd`) | Read-write |
| Rest of the host filesystem | Not visible |
| `/tmp` | Private and writable, in memory (an overlay over the root tree's empty `/tmp`); read-only under `--write=none` |
| Network | Outbound: clients can connect anywhere except link-local and the cloud metadata endpoints, servers can't announce |
| Host commands (`#C`) | Masked |
| Environment | Only the default guest variables plus `--env` |
| Memory | The guest-physical region size (1 GiB; `--memory` sets it, up to 32 GiB) |
| Processes, CPU, timeout | Unlimited, so interactive sessions and long builds aren't cut off |
| Terminal | `cons` and `consctl` only; no host ioctls such as `TIOCSTI` |

`--profile=tight` differs in three ways: the cwd is read-only (an overlay under `--write=ephemeral`), `#I` is masked, and a default timeout of 10 minutes applies. Its root is an overlay and its `/tmp` private and writable, as in the default profile, since neither writes the host; `--write=scope` keeps a read-only root in either profile. `--sandbox DIR` is the tight profile with only DIR bound, read-write, as the cwd; the host cwd isn't bound.

### Discarded root changes

The root overlay reports each create, copy-up, remove, and wstat to the machine once the namespace is built, so the `$home` the builder makes isn't counted. After a run, `Machine.root_changes` (a `RootChanges` value) says whether the guest changed the root outside `$home`, which top-level directories it changed, and whether it changed `$home`. When it changed the root outside `$home` and stderr is a terminal, the CLI prints `h9: changes to the root under /386, /lib were discarded (--dir DIR:/:up keeps them in DIR)` (for a 9P root, `(rerun with --write=scope to keep them)`). Scripts, whose stderr is rarely a terminal, don't see it.

### The root overlay's cost

Every walk in the root goes through `#O`: a lookup in its memory tree, then the lower device. A lower directory keeps the mounts made on it before the overlay (`findmount` in `src/kern/chan.zig` asks `#O` for the lower device when a mount hash bucket has an entry for the same qid path), which only a namespace file's overlay over `/` needs.

Measured on the emulator (Linux x86_64, 4 cores, best of 7 runs, `--write=overlay` against `--write=scope`): `du -a /sys/src`, twenty `ls -l` of `/bin`, `/lib`, and `/sys/include`, and `mk -n cat.install` in `/sys/src/cmd` all differ by less than 4%, within run-to-run noise, and the `[baseline]` suite passes the same cases either way.

On HVF (M-series MacBook Pro), `zig build proposal -Dp=baseline` takes 27.29 s with the overlay against 27.05 s without (median of 3), under 1%, and the `du -a /sys/src` (9747 entries) and `ls -l` loop above takes 0.45 s with it against 0.44 s without (median of 3), within noise. No fast path in `#O` was needed.

### Plans

A plan ([plan-format](../design/plan-format.md)) is the whole of what a machine is, as text: its namespace, its policy, its limits, and what it runs. Every way of starting a machine takes one: `h9 --plan FILE`, the flags (which compile to one, and `--print` writes it), `Machine.Options.plan` (with `Options.toPlan` as its inverse), and the page's `createMachine({ plan })`. `src/policy.zig` has the format: `Spec` is a plan's contents, `parsePlan` reads one, `Spec.write` writes one, and `narrow` is the narrowing rule.

The syntax is namespace files': a word and its arguments, separated by blanks, `'` quoting with `''` for a quote, and `;` or a newline between lines. A line that starts with `#` is a comment to its end, and a `#` that starts a word comments out the rest of its line up to a `;`. A line h9 doesn't know, or a value it can't take, is an error with the line number (`--plan` exits 2).

| Line | Meaning |
| --- | --- |
| `dir VALUE`, `url VALUE`, `archive VALUE`, `builtin [VALUE]`, `tmp VALUE` | A mount, its value a mount flag's (`SRC:DST:OPTS`, or the long form `src=…,dst=…`); bare `builtin` is the bottom of `/`. Mount lines come first, in order |
| `bind SRC:DST[:OPTS]` | A `--bind`, after the mounts |
| `bind`, `mount` with two values or more, `unmount`, `cd`, `clear` | Namespace lines, replayed as `--ns` replays them, after the binds and in order |
| `profile default\|tight` | The profile, and the defaults it sets |
| `write none\|scope\|ephemeral\|overlay`, `net disable\|outbound\|enable`, `netallow PATTERN` | The write mode, the network mode, and each network pattern |
| `allow read PATH`, `allow write PATH`, `deny read PATH` | `--readable`, `--writable`, and `--read-deny` |
| `devices [host-fs] [guest-tools]` | All of `#U`, and `#H/bin`, h9's own commands; a word left out is off |
| `memory SIZE`, `pids N`, `cpus N`, `timeout DURATION` | The limits |
| `engine E`, `arch A` | The engine and the architecture |
| `env NAME=VALUE` | A guest environment variable |
| `cwd PATH rw\|ro` | The host directory at `/mnt/term/cwd`, and whether it's writable |
| `gfx window [noclip] [scale=N]`, `gfx headless [WxH]` | A window or the headless screen |
| `serve ADDR`, `serveroot PATH`, `servetoken @FILE`, `serveorigin ORIGIN`, `servenet` | Serving, as the `--serve` flags do; the token is named by its file, never written in |
| `run PROG ARGS...` | What runs. Optional: a program on the command line replaces it |

Host paths are taken as written, and the CLI resolves relative ones from its working directory, as it does a flag's. A mount line after a bind or namespace line, and a `bind SRC:DST` after a namespace line, are errors, since the order wouldn't be the one h9 runs them in.

Flags given with `--plan` narrow it, and so will a child machine's plan under its parent's, with the same function, `policy.narrow(arena, base, by, why)`: a lower limit, a path or mount made read-only, a network pattern or mode taken away, a path denied, or a device left out is taken, and anything wider is `error.Widens`, with `why` naming the base's line (`memory 1G widens the plan's line 4: memory 256M`). [Flags as plan lines](cli.md#flags-as-plan-lines) lists what each flag may do.

A URL's query and a header's inline value can hold a secret. A plan writes them as `…`, and `parsePlan` refuses a line with `…`, so a printed plan never runs a different machine quietly; a plan names a secret in a file (`header=@FILE`, `servetoken @FILE`) instead. An embedder's `.fd` connection can't be text either: `--print` writes it as a comment, and `Machine.Options.plan` takes it from the other options, beside the plan.

### Pinned roots

A `url` line can carry `b3=HASH`, the BLAKE3 hash, in hex, of the tree's index ([mount-index](../design/epoch-0/mount-index.md)), so a plan with every root pinned is the same machine wherever it runs. h9 hashes the index text it reads on the host before the tree is used: an `index=` file or URL, or a static tree's `/.fs/index`. One with another hash is exit 125 (`h9: root tcp!fs.example!564: b3=: its index has hash 5b52186b2ff15513…, not the pinned 0b52186b2ff15513…`), as is a pinned index that's too big or doesn't compile, which an unpinned one would ignore. A pinned index is read afresh, not taken compiled from the cache.

A server's own `.fs/index` is read inside `#ι` once the connection is in use, so h9 can't check it first: a pinned mount with only that, or under `--index none`, is exit 125 rather than taken unchecked. Pin a 9P server's tree with `index=`, or serve it as a static tree. The pin covers the index, the tree's names, metadata, and file hashes; a static tree's files are checked against those hashes as they're read, and a 9P server's are what it serves.

### Plan output

`--print` compiles the flags and exits without running. It writes the plan they compile to, with every default spelled out, so `h9 --plan <(h9 FLAGS --print)` runs the same machine, and then what h9 builds from it, as comments a plan doesn't read back: the compiled policy, the namespace in `newns` format, the access rules, and the caveats. The namespace comment lines, without their `# `, can be saved and replayed with `--ns`:

```text
$ h9 --print --profile=tight --writable ./out --memory 512m --timeout 1m mk
# h9 plan (design/plan-format.md): h9 --plan FILE runs it

# namespace
dir /Users/me/h9root:/

# policy
profile tight
write overlay
net disable
allow write /Users/me/src/proj/out
devices guest-tools

# limits and the run
memory 512M
# pids: unlimited
# cpus: as many as the engine runs
timeout 1m
engine auto
arch arm64
cwd /Users/me/src/proj ro
run mk

# What h9 builds from these lines (comments, not read back):
# profile:  tight
# enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope ipc.restrict kernel.isolation net.disable proc.timeout res.memory
# limits:   write=overlay net=disable memory=512M timeout=1m
# devmask:  #C #I #ℏ #U #ū #ι #b #i #m #μ
# namespace:
#   bind '#/' /  # the kernel's names: bin dev env fd net proc root srv
#   bind -r '#U/Users/me/h9root' '#Oroot' ro
#   bind -c '#O' '#Oroot'                                  eph
#   bind -ac '#Oroot' /
#   bind '#Oroot' /root  # $rootdir: the root stack without the namespace's binds
#   bind -c '/root/mnt' /mnt
#   bind '#c' /dev
#   bind -b '#y<id>' /dev
#   bind -c '#e' /env
#   bind '#d' /fd
#   bind '#p' /proc
#   bind -c '#s' /srv
#   bind -a '#ℓ' /net  # 9P2000.L mounts
#   bind '/arm64/bin' /bin
#   bind -a '/rc/bin' /bin
#   bind -a '#H/bin' /bin  # h9's commands
#   bind -b '#H/over' /bin  # h9's bind, with -r
#   bind -c '#O' /tmp                                      eph
#   bind '#U/Users/me/src/proj' /mnt/term/cwd ro
#   bind -c '#U/Users/me/src/proj/out' /mnt/term/cwd/out rw
# access:
#   eph  /Users/me/h9root
#   ro   /Users/me/src/proj
#   rw   /Users/me/src/proj/out
# caveats:
#   - writes to the root are kept in memory, count against --memory, and are lost when the machine ends; when memory runs out they fail with "file system full"
#   - a file opened for writing is copied into memory whole the first time
#   - hardlinks under writable paths can modify host files outside them
#   - writes to writable paths are not capped (no res.disk)
#   - paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check
#   - the h9 process itself is not host-sandboxed
```

The caveats come from one function, `policy.writeCaveats`, so a new one has one place to go. The paragraphs below describe the compiled namespace, the part after `# namespace:`.

A 9P mount is printed as `mount 'URL' DST '<spec>'`, followed by its settings as namespace files take them (`'user=NAME'`, `'ca=FILE'`, and a `'header=@FILE'`), with `9p` in the access column and the connection (and `user=`, as `as NAME`) in a comment; on a stack, as `mount -r 'URL' '#Oroot'`. The URL is the one h9 connects to: `http://` and `https://` stay as given, so a replay probes again, and their comment adds "or a static tree". The spec is always written, `''` when empty, so a replay can tell it from the column; the line replays with `--ns`, which connects again.

A 9P mount has no access rule. On a stack under an overlay, nothing reaches its server; under `--write=scope` the server decides what can be written, and the plan says so in a caveat. Another caveat covers a TCP root's unencrypted connection.

`--write=none` with a 9P mount is exit 2, because h9 can't make devmnt read-only.

A WebSocket mount's comment is its URL with the query elided (`?…`), its headers with their values as `…`, the proxy it goes through (credentials as `…@`), `ca=`, and `cred PATTERN=COMMAND` for the credential helper that matches it, and the unencrypted caveat applies to `ws://` but not `wss://`. A helper's output never appears in the plan.

`/net/ws`'s bind is printed as `bind -a '#ℏ' /net`, and `ℏ` joins the `devmask:` line under `--net=disable`. `--trace` prints no write data, so a URL written to a `ctl` doesn't appear in a trace.

The built-in root is printed as `bind '#Hroot' /` with `builtin` in the access column and what it holds in a comment (`h9 v0.2.0, 9front 11952 slim`, or `skeleton only`). It's constant data, so it has no access rule, `--writable` can't name it, and it's read-only whatever the flags; the root's overlay and `/tmp` go over it as over a 9P root, as bare `#O`s. `--builtin=before` and `--builtin=after` print their `#Hroot/$cputype/bin` bind with `builtin` too. The lines replay with `--ns` as ordinary binds, so a plan printed over the built-in root replays on any h9 of the same build.

`--net-allow` patterns are printed in a `net-allow:` section after `devmask:`, as well as the plan's `netallow` lines.

The root's overlay is printed as `bind -c '#O' /` with `eph` and, over a host tree, the root's path in a comment, and the root's access rule as `eph`. Replayed with `--ns`, the line overlays whatever `/` is at that point; binds made before it onto directories of the root (the builder's own, when replaying into a running plan) are hidden under it, and the replay's later lines redo them, except `#U` binds, which the device mask refuses. The guest's cwd stays where the builder put it.

### Ephemeral writes

`--write=ephemeral` binds each path `scope` would make writable (the cwd, in the tight profile too, and each `--writable` path) as a `#O` overlay over its `#U` tree, printed as `bind -c '#O' <target>` with `eph` and the host path in a comment. Reads come from the host tree; creates, writes, removes, and renames land in memory. The root is an overlay too, `--writable` or not.

The overlay device (`src/kern/dev/overlay.zig`) keeps a tree in memory over a lower chan: a walk looks in memory first and falls through to the lower device, so devfs's checks (`--read-deny`, hidden paths, symlink resolution) apply to every lower lookup.

A memory node is a copy (a file or directory with its own data), a whiteout (a removed lower name), a directory marker (a lower directory with changed children) or a symbolic link a Linux program made (see Linux ABI).

A lower file is copied up whole the first time it's opened for writing, or not read at all with `OTRUNC`; a process that already has the lower file open keeps reading it. Renaming a lower directory, or a marker, is refused ("permission denied").

Copies' data is page-sized blocks and the nodes, names, and `Dir` strings come from a small allocator on the same pages, all from the machine's guest-physical page allocator through Zig leaves (`h9_overlay_alloc` in `src/kern.zig`), so ephemeral files count against `--memory` and running out fails the operation with "file system full", changing nothing.

Instances are made by the namespace builder (`h9_overlay_newpath`) and attached as `#O<n>`; attaching checks the instance belongs to the caller's machine, and the last close of its last chan frees it. In a namespace file, a bind from a bare `#O` makes a fresh instance over what its target is at that point in the replay. Ephemeral changes can't be exported yet.

### Up layers

The `up` mount option ([upper-layers](../design/epoch-0/upper-layers.md)) makes a writable tree, a `--dir`, a `--url` to a writable 9P server (a port on the web host too), or a `--tmp`, the layer that takes every change over what's beneath it: on `/` or `#L`, every other member of the stack, with the layer on top whatever its order; elsewhere, what's at DST when the mount is made. It's printed as `bind -u NEW OLD` with `up` in the access column, and `--ns` replays it. The layer is the stack's up member (see the overlay device in [kernel.md](kernel.md)), so the changes land in it as an unpacked OCI layer, with copies of the files the guest changed, `.wh.NAME` for names it removed, and `.wh..wh..opq` in directories it removed and made again, and none of it in memory. A stack with an up member has no overlay. `up` with `ro`, `rw`, or `eph`, a second `up` member on one stack, `up` on `--archive` or `--builtin`, and `up` under `--write=none` or `--write=ephemeral` are exit 2. A layer on a host directory owns its files as the user h9 runs as. A layer is written as the guest goes, so a run that fails leaves part of one.

Every stack reads whiteouts in every member, so a layer mounts again, without `up`, as it was, under a new layer or by itself. `--archive` unpacks an archive's `.wh.` entries as files, which a stack then reads as whiteouts; off a stack they're plain files, as is a `.wh.` file in any tree that isn't a stack member.

### Examples

```sh
h9 --profile=tight ls -l                                  # read-only, no network
h9 --net=disable --writable ./out --rc 'mk install'        # writes only to ./out
h9 --memory 256m --pids 32 --cpus 2 --timeout 30s rc       # resource caps
h9 --readable ~/src/proj --read-deny ~/src/proj/.env \
    --rc 'grep -n TODO /mnt/term/$home/src/proj/*.c'       # read a tree, hide secrets
h9 --rc 'echo hi > /lib/x && cat /lib/x'                  # the root is writable; /lib/x vanishes at exit
h9 --writable "$H9ROOT" --rc 'cd /sys/src/cmd && mk install'  # install into the root tree for real
h9 --net=enable aux/listen1 -t tcp!*!8080 /bin/cat           # a server needs --net=enable
h9 --net-allow 'tcp!*.example.com!443' myclient              # egress by name, through cs
```

Host paths given to `--readable` and `--writable` appear in the guest under `/mnt/term/<host path>`, as in drawterm; the cwd stays at `/mnt/term/cwd`.
