# The sandbox

This describes, as built, h9's security stance and the sandbox policy: what a guest can reach on the host, and how the policy is compiled, checked, and printed. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Security stance](#security-stance)
- [Sandbox policy](#sandbox-policy)
  - [Vendor hooks](#vendor-hooks)
  - [Network rules](#network-rules)
  - [Access rules](#access-rules)
  - [Path resolution](#path-resolution)
  - [Contained trees](#contained-trees)
  - [Linux symlinks](#linux-symlinks)
  - [Default profile](#default-profile)
  - [Discarded root changes](#discarded-root-changes)
  - [The root overlay's cost](#the-root-overlays-cost)
  - [Plan output](#plan-output)
  - [Ephemeral writes](#ephemeral-writes)
  - [Examples](#examples)

## Security stance

**Security stance.** The hypervisor isolates guest memory and the CPU, and every guest syscall is served by drawterm's kernel rather than the host's, so the guest never reaches host syscalls, ioctls, or the host environment directly. The namespace decides what a guest can reach on the host. Identity: hostowner is the host user's name; devfs maps the host's file ownership onto Plan 9 user strings.

## Sandbox policy

Sandboxing is a `Policy` in `Machine.Options`: a set of capabilities, host paths, network rules, and limits. The capability model follows [isobox](https://github.com/can1357/isobox): named capabilities, profiles that set defaults, explicit flags that override them, and a printable plan with caveats. Unlike isobox, enforcement lives in the shared kernel, so the capability set is the same on every vmm backend; there's no per-host intersection to compute.

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
| `proc.timeout` | A machine deadline: a `hangup` note to every process, then a hard teardown after a 2 s grace period |
| `res.pids`, `res.cpu` | A cap on live processes in `rfork`; a cap on vCPUs running guest code at once |

### Vendor hooks

The policy lives in Zig. drawterm calls it through leaf functions, following seam rule 3.

devfs-posix and devfs-win32 call `h9_fs_check(path, op)` (in `src/kern/fscheck.c`) before each walk, open, create, remove, wstat, and directory entry. It resolves the host path and asks the Zig leaf `h9_policy_check` for a verdict: allowed, hidden (the walk fails, or the entry is left out of the listing) or read-only ("permission denied").

devip calls `h9_net_check(op, proto, addr, port)` (declared in `src/kern/netcheck.h`) when a ctl file's `connect` or `announce` is parsed, before a port is bound or the host is dialed, and raises "permission denied" on a refusal.

Its `cs` calls `h9_net_lookup(proto, name, port)` before the host's resolver, raising "no translation for host found" for a name no pattern covers, and `h9_net_resolved` after it.

The machine's compiled plan is set per host thread, because each guest process runs on its own thread. The leaves return an int and never raise kernel errors themselves.

### Network rules

Under `--net=outbound` (the default profile's setting) `announce` is refused; `--net=enable` allows it.

Without `--net-allow`, a `connect` to link-local addresses (169.254.0.0/16, fe80::/10) is refused in both modes, which keeps the common cloud metadata endpoint out of reach, and everything else is allowed.

With patterns, the patterns are the whole policy: a `connect` must match one, by protocol (`tcp`, `udp`, or `net`/`*`), address (an address, a CIDR range, or `*`) and port (a number, a range, or `*`). IPv4 is matched as IPv4, however devip spelled it.

A name pattern (`api.example.com`, or `*.example.com` for one or more labels) can't be checked at `connect`, whose message is numeric, so `cs` resolves only names a pattern covers and records what each returned in the machine's resolved-name table (the 1024 most recent entries). A later `connect` to a recorded address is allowed if its name matches a name pattern with that protocol and port.

A `/net/ws` `connect` is checked as a TCP dial to the URL's host and port: a name goes through the same lookup check and resolved-name table, and each address it resolves to through the connect check.

Connections h9 makes itself (a root, a namespace-file mount) are outside the policy, and the guest can't reach them by name. `--net-allow` with `--net=disable`, or a bad pattern, is exit 2.

### Access rules

The plan's rules are the root, the cwd, each `--readable` and `--writable` path, and each `--read-deny` path, all as resolved host paths. Overlaid paths (`eph`) are read-only rules, since the overlay never writes its lower tree. A deny rule covering a path wins. Otherwise the longest allow rule covering the path decides between read-only and read-write. Ancestors of allowed paths can be walked and listed but not changed, so `/mnt/term/<path>` works when the host's `/` is unioned after the tree's `/mnt/term`. Anything else is hidden. Bind-level read-only (no `MCREATE`) is a second, coarser check.

### Path resolution

For a 9front program, devfs-posix follows symlinks with `stat`, so a symlink inside a bound tree can point anywhere on the host. A Linux program's walks don't follow them ([Linux symlinks](#linux-symlinks)).

Every devfs path is resolved and the resolved path is checked against the access rules, on every host. On Linux a clean absolute path is first looked up with one `openat2` with `RESOLVE_NO_SYMLINKS`; if it holds no link it is already canonical, and otherwise it's resolved by an `O_PATH` open and its `/proc/self/fd` name, so a check costs a constant number of calls however deep the path is (`realpath` reads every element with a `readlink`, so a walk down a tree cost the square of its depth). Linux without `openat2` or `/proc`, macOS, and the web host use `realpath`, and Windows the final path of an opened handle, which follows symlinks and junctions and refuses UNC and device paths.

Create, remove, and rename act on the name rather than a link's target, so an existing entry is checked by its own canonical name without following it. On macOS that's `F_GETPATH` on an `O_SYMLINK` open, and on Windows the final path of a reparse-point open, so another case, an 8.3 short name, or a trailing dot can't dodge a rule on a case-insensitive file system. A new name is appended to its resolved parent. A create over an existing symlink also checks the link's target for writing.

Renaming a directory that has any rule strictly beneath it is refused ("permission denied"), because it would move those paths out from under their rules. The check and the host call aren't atomic, so a host process renaming paths at the same time can race it; the plan reports that, and hardlinks under writable paths, as caveats.

### Contained trees

A bind from `#U!c/path` ([symlinks-in-root](../design/epoch-0/symlinks-in-root.md)) is *contained*: devfs resolves its links itself, inside the tree, as `openat2`'s `RESOLVE_IN_ROOT` does.

The tree's top is where namec's walk from the `#U!c` attach ends (`h9_fs_anchor`, called from the vendored `chan.c`), canonicalised.

Each later walk looks names up one at a time with `lstat` (`h9_fs_resolvein` in `src/kern/fscheck.c`; on Windows `h9_fs_resolveinw`, which reads symlinks and junctions with `FSCTL_GET_REPARSE_POINT` and refuses other reparse points and UNC targets): a link's target is read, an absolute one starts again at the top (on Windows, with its drive dropped), a relative one from the link's directory, `..` at the top stays there, and more than 40 links in one walk is "too many symbolic links".

The resolved path, which holds no links, is checked against the access rules as any other path is, so `--read-deny` and partly allowed trees still apply, and kept on the chan with the link's own path beside it: stat shows the link's name, remove and rename act on the link, and open, read, and wstat on its target.

A listing shows each link with its target's `Dir` and leaves out a link whose target is missing or loops, since walking it fails.

`h9_fs_readlink` (and `h9_fs_readlinkpath` by guest path, through the root overlay; `kern.readlink`) gives a link's target as written, for the Linux personality; Plan 9 programs never see links.

These rules are a 9front program's. For a Linux program the boundary is the process's root instead of the tree's top ([Linux symlinks](#linux-symlinks)).

An uncontained `#U` attach is unchanged. `--dir PATH:DST:contained`, and every `--dir` on `#L`, makes that mount's bind contained; other binds, including writable paths inside it, stay uncontained. `--print` shows it as `bind '#U!c/path' DST`, which replays with `--ns` where `#U` isn't masked. Any other `#U` attach spec is "bad attach specifier".

### Linux symlinks

A Linux process's walks ([linux-symlinks](../design/linux-symlinks.md)) stop at a link instead of following it, and the kernel's walk follows it from the process's root, the Linux view, so a link resolves through the same mounts, binds, and `#L` layers as the path the program would get by writing its target out. A 9front process's walks are unchanged. A process walks this way when its root is the Linux view (`h9_fs_linkwalk`, `src/kern/linux.c`).

A device's walk stops at the first link it meets: the link is the last qid of its `Walkqid`, with `H9_QTSYMLINK` (`0x02`, 9P2000.u's and .L's qid bit) in its type, and the names after it aren't walked. The link `stat`s with `H9_DMSYMLINK` (9P2000.u's `0x02000000`) and its own size and times, and a directory read lists it so, with or without a target. devfs (posix and win32, contained or not), the overlay's `Nlink` nodes and its lower tree's links, a union's members, and a 9P2000.L mount ([ninep.md](ninep.md)) stop this way. `namec` refuses to open a link that a Linux open didn't follow, on any device.

devfs looks each name up with `lstat` (on Windows, `FindFirstFile`, whose entry for a symbolic link or junction isn't followed) and checks it against the access rules by its own path (`h9_fs_checkname`) rather than its `realpath`. A walk's path holds no links, from a canonical start (the first such walk from a chan `realpath`s it), so `..` is its parent, and it stops at a contained tree's top. An open of the walked path doesn't follow a link that appeared since: on Linux it's an `openat2` with `RESOLVE_NO_SYMLINKS`, elsewhere (and on Linux kernels without `openat2`) a chain of `openat`s with `O_NOFOLLOW` from `/`, and on Windows an open of the reparse point itself, refused if it is one. A link swapped in after the walk fails the open ("too many symbolic links") instead of being followed by the host, and a create doesn't follow a link left in its name. The web host, with no `/` to start from, refuses a link only as the last name.

`walk()` in the vendored `chan.c` follows a link when a walk stopped at one with names left, or at the last name of a lookup that follows links (`followlink`): it reads the target (`h9_fs_chanreadlink`, down through overlays and unions to the tree that holds it) and walks it, an absolute target from the process's root and a relative one from the link's directory as the walk reached it, then the rest of the path. A mount point before the link is crossed first. The result's name is the target's, so `..` after a link is the target's parent, and `getcwd` after a `chdir` through one is the target's path. More than 40 links in one lookup is "too many symbolic links". A lookup follows a link in its last name unless it's a remove or the call says not to (`h9_fs_nofollow`, per process): `lstat`, `readlink`, `rename`'s old name, and `O_NOFOLLOW`. `namec`'s `h9_fs_anchor` call, after the walk, is unchanged.

A 9P2000.L mount follows its own links, from its attach root, only for a 9front process ([ninep.md](ninep.md)).

### Default profile

With no sandbox flags the guest can work in the host cwd and nothing else:

| Area | Default |
| --- | --- |
| Root tree (`/`) | Read-only underneath, with an ephemeral overlay: writes succeed in memory, count against `--memory`, and vanish at exit, for a host tree, a 9P root, and the built-in root alike. `$home` (`/usr/$user`) is made in the overlay if the root lacks it. Installing into the root needs `--writable "$H9ROOT"`; `--write=scope` makes it read-only, and a 9P root then as writable as its server allows |
| Host cwd (`/mnt/term/cwd`) | Read-write |
| Rest of the host filesystem | Not visible |
| `/tmp` | Private and writable, in memory (an overlay over the root tree's empty `/tmp`); read-only under `--write=none` |
| Network | Outbound: clients can connect anywhere except link-local, servers can't announce |
| Host commands (`#C`) | Masked |
| Environment | Only the default guest variables plus `--env` |
| Memory | The guest-physical region size (1 GiB; `--memory` sets it, up to 32 GiB) |
| Processes, CPU, timeout | Unlimited, so interactive sessions and long builds aren't cut off |
| Terminal | `cons` and `consctl` only; no host ioctls such as `TIOCSTI` |

`--profile=tight` differs in three ways: the cwd is read-only (an overlay under `--write=ephemeral`), `#I` is masked, and a default timeout of 10 minutes applies. Its root is an overlay and its `/tmp` private and writable, as in the default profile, since neither writes the host; `--write=scope` keeps a read-only root in either profile. `--sandbox DIR` is the tight profile with only DIR bound, read-write, as the cwd; the host cwd isn't bound.

### Discarded root changes

The root overlay reports each create, copy-up, remove, and wstat to the machine once the namespace is built, so the `$home` the builder makes isn't counted. After a run, `Machine.root_changes` (a `RootChanges` value) says whether the guest changed the root outside `$home`, which top-level directories it changed, and whether it changed `$home`. When it changed the root outside `$home` and stderr is a terminal, the CLI prints `h9: changes to the root under /386, /lib were discarded (rerun with --writable "$H9ROOT" to keep them)` (for a 9P root, `--write=scope`). Scripts, whose stderr is rarely a terminal, don't see it.

### The root overlay's cost

Every walk in the root goes through `#O`: a lookup in its memory tree, then the lower device. A lower directory keeps the mounts made on it before the overlay (`findmount` in `third_party/drawterm/kern/chan.c` asks `#O` for the lower device when a mount hash bucket has an entry for the same qid path), which only a namespace file's overlay over `/` needs.

Measured on the emulator (Linux x86_64, 4 cores, best of 7 runs, `--write=overlay` against `--write=scope`): `du -a /sys/src`, twenty `ls -l` of `/bin`, `/lib`, and `/sys/include`, and `mk -n cat.install` in `/sys/src/cmd` all differ by less than 4%, within run-to-run noise, and the `[baseline]` suite passes the same cases either way.

On HVF (M-series MacBook Pro), `zig build proposal -Dp=baseline` takes 27.29 s with the overlay against 27.05 s without (median of 3), under 1%, and the `du -a /sys/src` (9747 entries) and `ls -l` loop above takes 0.45 s with it against 0.44 s without (median of 3), within noise. No fast path in `#O` was needed.

### Plan output

`--print` compiles the policy and exits without running. The namespace is printed in `newns` format, so it can be saved and replayed with `--ns`:

```text
$ h9 --print --profile=tight --writable ./out --memory 512m --timeout 1m mk
profile:  tight
enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope ipc.restrict kernel.isolation net.disable proc.timeout res.memory
limits:   write=overlay net=disable memory=512M timeout=1m
devmask:  #C #I #ℏ #U #ι #b #i #m
namespace:
  bind '#U/Users/me/h9root' /                             ro
  bind -c '#O' /                                          eph  # /Users/me/h9root
  bind '#c' /dev
  bind -b '#y<id>' /dev
  bind -c '#e' /env
  bind '#d' /fd
  bind '#p' /proc
  bind -c '#s' /srv
  bind '/arm64/bin' /bin
  bind -a '/rc/bin' /bin
  bind -a '#H/bin' /bin  # h9's commands
  bind -c '#O' /tmp                                       eph  # /Users/me/h9root/tmp
  bind '#U/Users/me/src/proj' /mnt/term/cwd                ro
  bind -c '#U/Users/me/src/proj/out' /mnt/term/cwd/out     rw
access:
  eph  /Users/me/h9root
  ro   /Users/me/src/proj
  rw   /Users/me/src/proj/out
caveats:
  - writes to the root are kept in memory, count against --memory, and are lost when the machine ends; when memory runs out they fail with "file system full"
  - a file opened for writing is copied into memory whole the first time
  - hardlinks under writable paths can modify host files outside them
  - writes to writable paths are not capped (no res.disk)
  - paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check
  - /proc/n/ns shows the host paths of bound host trees
  - the h9 process itself is not host-sandboxed
```

A 9P mount is printed as `mount 'URL' DST '<spec>'`, followed by its settings as namespace files take them (`'user=NAME'`, `'ca=FILE'`, and a `'header=@FILE'`), with `9p` in the access column and the connection (and `user=`, as `as NAME`) in a comment; on a stack, as `mount -r 'URL' '#Oroot'`. The URL is the one h9 connects to: `http://` and `https://` stay as given, so a replay probes again, and their comment adds "or a static tree". The spec is always written, `''` when empty, so a replay can tell it from the column; the line replays with `--ns`, which connects again.

A 9P mount has no access rule. On a stack under an overlay, nothing reaches its server; under `--write=scope` the server decides what can be written, and the plan says so in a caveat. Another caveat covers a TCP root's unencrypted connection.

`--write=none` with a 9P mount is exit 2, because h9 can't make devmnt read-only.

A WebSocket mount's comment is its URL with the query elided (`?…`), its headers with their values as `…`, the proxy it goes through (credentials as `…@`), `ca=`, and `cred PATTERN=COMMAND` for the credential helper that matches it, and the unencrypted caveat applies to `ws://` but not `wss://`. A helper's output never appears in the plan.

`/net/ws`'s bind is printed as `bind -a '#ℏ' /net`, and `ℏ` joins the `devmask:` line under `--net=disable`. `--trace` prints no write data, so a URL written to a `ctl` doesn't appear in a trace.

The built-in root is printed as `bind '#Hroot' /` with `builtin` in the access column and what it holds in a comment (`h9 v0.2.0, 9front 11952 slim`, or `skeleton only`). It's constant data, so it has no access rule, `--writable` can't name it, and it's read-only whatever the flags; the root's overlay and `/tmp` go over it as over a 9P root, as bare `#O`s. `--builtin=before` and `--builtin=after` print their `#Hroot/$cputype/bin` bind with `builtin` too. The lines replay with `--ns` as ordinary binds, so a plan printed over the built-in root replays on any h9 of the same build.

`--net-allow` patterns are printed in a `net-allow:` section after `devmask:`.

The root's overlay is printed as `bind -c '#O' /` with `eph` and, over a host tree, the root's path in a comment, and the root's access rule as `eph`. Replayed with `--ns`, the line overlays whatever `/` is at that point; binds made before it onto directories of the root (the builder's own, when replaying into a running plan) are hidden under it, and the replay's later lines redo them, except `#U` binds, which the device mask refuses. The guest's cwd stays where the builder put it.

### Ephemeral writes

`--write=ephemeral` binds each path `scope` would make writable (the cwd, in the tight profile too, and each `--writable` path) as a `#O` overlay over its `#U` tree, printed as `bind -c '#O' <target>` with `eph` and the host path in a comment. Reads come from the host tree; creates, writes, removes, and renames land in memory. The root is an overlay too, `--writable` or not.

The overlay device (`src/kern/devoverlay.c`) keeps a tree in memory over a lower chan: a walk looks in memory first and falls through to the lower device, so devfs's checks (`--read-deny`, hidden paths, symlink resolution) apply to every lower lookup.

A memory node is a copy (a file or directory with its own data), a whiteout (a removed lower name), a directory marker (a lower directory with changed children) or a symbolic link a Linux program made (see Linux personality).

A lower file is copied up whole the first time it's opened for writing, or not read at all with `OTRUNC`; a process that already has the lower file open keeps reading it. Renaming a lower directory, or a marker, is refused ("permission denied").

Copies' data is page-sized blocks and the nodes, names, and `Dir` strings come from a small allocator on the same pages, all from the machine's guest-physical page allocator through Zig leaves (`h9_overlay_alloc` in `src/kern.zig`), so ephemeral files count against `--memory` and running out fails the operation with "file system full", changing nothing.

Instances are made by the namespace builder (`h9_overlay_newpath`) and attached as `#O<n>`; attaching checks the instance belongs to the caller's machine, and the last close of its last chan frees it. In a namespace file, a bind from a bare `#O` makes a fresh instance over what its target is at that point in the replay. Ephemeral changes can't be exported yet.

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
