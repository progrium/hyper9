---
slug: mounts
title: Mounts, binds, and a Plan 9 root
status: draft
created: 2026-11-20
authors: [progrium]
depends: [overlay, ninep-roots, websocket-9p, dotl, linux-personality, builtin-root, symlinks-in-root]
areas: [cli, kern, sandbox, web, api]
branch: []
---

# Proposal: Mounts, binds, and a Plan 9 root

## Abstract

A machine's namespace is set up with one family of flags, each of which becomes one line of the plan. Mount flags bring a tree in from outside the machine: `--dir` for a host directory or file, `--url` for a 9P server over `tcp://`, `unix://`, `ws://`, or `wss://`, or a static tree over `http://` or `https://`, `--archive` for a tar unpacked into memory, `--builtin` for the built-in root, and `--tmp` for an empty tree in memory. `--bind` rearranges what's already inside. All of them take `SRC:DST[:OPTS]`, with options such as `ro`, `rw`, `eph`, `b`, `a`, `c`, and `r`. Mounts on `/` stack into one tree merged at every depth, which replaces the proposed `--layer`, and mounts on `#L` (devlinux, renamed from `#λ`) do the same for the Linux tree. `/` is built as on 9front: the kernel's `#/` first, with the root stack unioned behind it and bound at `/root`, so a remote root is never asked for `/dev` or `/proc`. `--root` and its `--root-*` flags are removed, and so is detecting a Linux tree by its contents. `--print` output is exactly what `--ns` replays, Linux trees and 9P options included. This proposal takes in [recursive-unions](recursive-unions.md)' union instances and [host-srv](host-srv.md)'s posting, and supersedes both.

## Background

### How roots are set up today

- **A host directory,** with `--root DIR`, `$H9ROOT`, the development tree, or the built-in root, in that order ([builtin-root](builtin-root.md)). The plan's first line is `bind '#U/…' / ro`.
- **A 9P server,** with `--root tcp!host!564`, `unix!/path`, or a socket's path ([ninep-roots](ninep-roots.md)), `ws://` or `wss://` ([websocket-9p](websocket-9p.md)), or a URL without a scheme ([schemeless-roots](schemeless-roots.md)). A .L server works with no flag ([dotl](dotl.md)). `--root-spec`, `--root-user`, `--root-header`, and `--root-ca` configure the connection. h9 posts it as `/srv/root` and mounts it at `/`.
- **A Linux tree,** with a second `--root`, recognised by `/etc/os-release` or a `/lib/ld-*` loader ([linux-personality](linux-personality.md)). It's unioned after devlinux's directories at `#λ`, and always contained ([symlinks-in-root](symlinks-in-root.md)).
- **The built-in root,** with `--builtin auto|only|before|after|off`. `before` and `after` add its commands to `/bin` only.
- **Writes** are set by `--write`: an `#O` overlay over the root by default ([overlay](overlay.md)), or the root read-only, or `--writable` to write through.
- **On the browser host,** `createMachine({ root, layers })` takes an archive or a WebSocket URL, plus archives unpacked over it.
- **In `Machine.Options`,** `root` is `.dir`, `.tcp`, `.unix`, or `.ws`, with `root_spec`, `root_user`, `root_headers`, `root_ca`, `root_contained`, `linux_root`, and `builtin`.
- **Everything else** goes in a namespace file. `--ns` replays it after the namespace is built and `#U` is masked, so it can't reach host paths except through `/mnt/term`, can't mount a unix socket, and can't set a WebSocket's headers.

That's three syntaxes for addresses (paths, dial strings, and URLs), a flag family per source, a different mechanism for the Linux tree, and a namespace file that can't express what the flags do.

### What's proposed but not built

- [recursive-unions](recursive-unions.md) adds `#O` instances with several members, `bind -r`, `#Oroot`, `#Olinux`, and `--layer DIR`. `--layer` was never built.
- [host-srv](host-srv.md) adds `--srv name=ADDR` to post connections to `/srv`.
- [tilde-roots](tilde-roots.md) adds `~name` roots. It's left alone here.
- [mount-index](mount-index.md) adds `/.h9index`. A 9P extension, [9p-dotfs](https://progrium.xyz/docs/proposals/9p-dotfs/), is meant to replace it with `.fs/index`, and this proposal uses dotfs's index for HTTP trees.

### `/` on 9front

On a standard 9front system, boot mounts the file server at `/root`, and `/lib/namespace` runs `bind -a $rootdir /`. The kernel's `#/` comes first, with its `bin`, `dev`, `env`, `fd`, `net`, `proc`, `root`, and `srv` directories, and the file server's tree comes after. A read-only file server can have nothing at `/dev` or `/proc`, and lookups of the kernel's names never leave the machine.

h9 replaces `/` with the root tree instead. With a remote root, every lookup of `dev`, `env`, `fd`, `proc`, `srv`, or `net` goes to the server first, about 9 to 15 requests at startup, and the tree has to carry empty directories for each. `/root`, which 9front scripts know as `$rootdir`, is whatever directory the tree has there, usually empty.

## Proposal

### Mount flags

Every mount flag is `SRC:DST[:OPTS]` and repeatable. They're applied in the order given, and `--help` lists them under Mounts. Only `--url` is a `mount` in Plan 9's sense, a 9P connection through devmnt. The others become `bind` lines in the plan, of `#U`, `#O`, or `#H`.

| Flag | SRC | Becomes |
| --- | --- | --- |
| `--dir PATH:DST[:OPTS]` | A host directory or file | A bind of `#U/PATH` |
| `--url URL:DST[:OPTS]` | A 9P server, or a static tree over HTTP (below) | A mount of the connection |
| `--archive FILE:DST[:OPTS]` | A tar, a gzipped tar, or an `.h9a` | A tree unpacked into memory |
| `--builtin[=DST[:OPTS]]` | The built-in root | A bind of `#Hroot` |
| `--tmp DST` | Nothing | An empty tree in memory: `bind -c '#O' DST` over an empty instance |

`--dir`'s PATH is resolved as `--cwd` is, and the host path joins the plan's access rules: readable, or writable with `rw`, so `--dir` grants exactly what it binds. A file binds onto a file. `--archive` FILE is a host path, read once before the program starts. Its tree is held in an `#O` instance with no member, counted against `--memory`, as the browser host's layers are now. `--builtin` with no destination means the bottom of `/`.

### URLs

| URL | Means |
| --- | --- |
| `tcp://HOST:PORT[/SPEC]` | 9P over TCP. The path, without its leading `/`, is the attach spec. |
| `unix:///PATH` | 9P over a unix socket at PATH. The spec is `spec=`. |
| `ws://…`, `wss://…` | 9P over a WebSocket, as now. |
| `http://…`, `https://…` | A WebSocket if the server upgrades, and otherwise a static dotfs tree (below). |
| `HOST[:PORT][/PATH]` | No scheme: as `http://` for a loopback host, and `https://` for any other. |

An IPv6 host is in brackets, as in any URL: `tcp://[::1]:564`. `spec=` on any URL wins over a spec in its path. Every 9P URL speaks 9P2000, 9P2000.L, or `9P2000.L.Z`, negotiated as now. [credential-helpers](credential-helpers.md)' `--cred` patterns, if that proposal is built, match every `http`, `https`, `ws`, and `wss` URL here, for handshakes, probes, index fetches, and reconnects alike.

**The probe.** For `http://`, `https://`, and a URL without a scheme, h9 sends one GET to the URL with WebSocket upgrade headers, offering the `9p` subprotocol. A `101` answer is a WebSocket connection, used as for `ws://` or `wss://`. Any other answer makes h9 fetch `URL/.fs/index`. A `200` makes it a static tree, and anything else fails with exit 125 and a message naming both attempts. So a server can answer the same URL both ways.

**Static trees.** A static tree is dotfs's read-only index profile served as plain files:

- **Index.** `URL/.fs/index`, with the header `fsindex 1 seq N`. h9 asks for zstd with `Accept-Encoding`. Walks, stats, and directory reads are answered from it. A directory flagged `i` has its own `URL/DIR/.fs/index`, fetched on first use.
- **Contents.** `GET URL/PATH`, with Range requests for reads past the first `msize`. A file whose index line has a `b3:` hash is checked against it, and a mismatch fails the read with "content changed". Contents are cached on the host by hash, so trees that share files share the cache. Files flagged `p` are fetched when the tree is mounted.
- **Read-only.** A static tree has no `events`, `ctl`, or `stage`, so writes to it fail. On `/` and `#L` the default `eph` gives the run a writable copy in memory.

h9 serves a static tree to the kernel as a 9P server on the host, in Zig, through a `#ℓ` conversation as dotl's translator is. On the browser host, it uses the page's `fetch`, under the page's CORS rules.

**Indexes on 9P servers.** A 9P server, local or remote, that has `.fs/index` at its attach root gets the same treatment: walks, stats, and directory reads come from the index, and only opens and reads go to the server. `index=URL|PATH` on any `--url` names an index hosted elsewhere, for a server that can't serve its own.

### Destinations

DST is a guest path:

- **`/`** is the 9front root stack, `#Oroot` (see Building `/`).
- **`#L`**, or a path under it, is the Linux tree's stack, `#Olinux`. devlinux, today `#λ`, is renamed `#L`.
- **`/srv/NAME`**, for `--url` only, connects to the server and posts the connection as `/srv/NAME` without mounting it, so a namespace file or a guest program mounts it with its own spec. This is what [host-srv](host-srv.md) proposed as `--srv`.
- **Any other path** is a bind or mount point, as `bind(1)` and `mount(1)` use it.

A DST that doesn't exist is made as a directory in the overlay of the stack it's under, if that stack has one (`eph`, the default). Otherwise it fails with exit 125: "--dir ./data:/app/data: /app/data does not exist (the root is read-only)".

### Stacks

`/` and `#L` are always stacks: `#O` instances with an ordered list of members, merged at every depth (see Union instances). Each mount flag with that destination adds a member. A later member goes on top, as in a Dockerfile, unless it says `a`, which puts it at the bottom, or `b`, which is the default and says so. So:

```sh
h9 --builtin --dir ./base:/ --dir ./app:/ --archive ./fix.tgz:/ rc
```

makes `/` from `fix.tgz` over `app` over `base` over the built-in root. Mounting into a stack at a path below its top, such as `--dir ./etcfix:#L/etc`, adds a member rooted at that path.

Any other destination takes Plan 9's rules: the mount replaces what's there, `b` and `a` make a one-level union with it, and `r` makes a union merged at every depth.

### `--bind SRC:DST[:OPTS]`

`--bind` binds a path already in the machine: SRC is a guest path or a `#` device, and DST is a guest path. Every `--bind` runs after every mount flag, in the order given, and before `--ns`, so it can bind out of anything mounted. The options are `b`, `a`, `c`, and `r`.

```sh
h9 --url wss://fs.example/9front:/ --dir ./proj:/usr/glenda/proj:rw \
   --bind /usr/glenda/proj/bin:/bin:b rc
```

### Options

Options follow DST, separated by commas. Each has a short and a long form, and `--print` writes the short one.

| Short | Long | Meaning |
| --- | --- | --- |
| `ro` | `readonly` | Read-only |
| `rw` | `readwrite` | Writes go to the source |
| `eph` | `ephemeral` | Writes land in memory and vanish when the machine ends |
| `b` | `before` | In front of what's at DST; on a stack, on top |
| `a` | `after` | Behind what's at DST; on a stack, at the bottom |
| `c` | `create` | Creates go to this member |
| `r` | `recursive` | Merge at every depth |
| `contained` | | `--dir` only: symlinks resolve inside the tree, as `--root-contained` does now. Always on under `#L`. |

| Setting | For | Meaning |
| --- | --- | --- |
| `spec=NAME` | `--url` | The attach spec |
| `user=NAME` | `--url` | The user name sent with the attach |
| `auth=…` | `--url` | Reserved for [root-auth](root-auth.md)'s p9any key |
| `index=URL\|PATH` | `--url` | A dotfs index for the tree, hosted elsewhere |
| `header=NAME: VALUE` or `header=@FILE` | `ws`, `wss`, `http`, `https` | A header on the handshake and index fetches; repeatable |
| `ca=FILE` | `wss`, `https` | A PEM file the server must chain to |

Two options that conflict, such as `ro,rw` or `b,a`, are a usage error (exit 2). A header given with `header=` wins over a credential helper's header of the same name.

**Write defaults.** A stack's write mode comes from `--write`: `eph` under `overlay` and `ephemeral`, and `ro` under `scope` and `none`. A member marked `rw` takes creates and writes, and the stack then has no overlay, as `--writable "$H9ROOT"` works now. Any other destination is `ro` unless it says `rw` or `eph`. Under `--write=none`, `rw` and `eph` are usage errors, and so is a 9P mount, as now.

### Parsing

DST starts at the last `:` in the argument that's followed by `/` or `#`. Whatever follows DST after a `:` is OPTS. A URL's scheme separator, its port, and an image tag (`wss://h:8080/alpine:3.20`) never put `/` or `#` right after a `:`, so `--url wss://reg.example/alpine:3.20:/` is SRC `wss://reg.example/alpine:3.20` and DST `/`.

For a value that has to contain `:` followed by `/`, or a `,`, there's a long form with keys, chosen when the argument starts with `src=`:

```sh
--url 'src=wss://fs.example/9p,dst=/,index=https://cdn.example/9p/.fs/index,"header=Authorization: Bearer abc"'
```

Fields are separated by commas, and a field in double quotes can hold commas, as in CSV and Docker's `--mount`. `header=@FILE` keeps a token off the command line.

### Building `/`

Every plan starts with `#/` and puts the root stack behind it:

```text
  bind '#/' /
  bind -r '#U/home/me/base' '#Oroot'                     ro
  bind -r -b '#U/home/me/app' '#Oroot'                   ro
  bind -c '#O' '#Oroot'                                  eph
  bind -a -c '#Oroot' /
  bind '#Oroot' /root
  bind '#c' /dev
  …
```

- **The kernel's names stay local.** drawterm's `#/` (`third_party/drawterm/kern/devroot.c`) has `bin`, `dev`, `env`, `fd`, `net`, `net.alt`, `proc`, `root`, and `srv`. Walks of those names are answered by `#/`, and the plan binds over each, so the root tree is never asked. A tree needs no empty mount points for them.
- **Other mount points** h9 binds onto, `/tmp` and `/mnt/term/cwd`, come from the tree as now. If the tree lacks them, they're made in the root's overlay, so a bare tree works under the default `--write`.
- **`/root`** is `#Oroot`: the root stack with nothing bound over it, as `$rootdir` is on 9front. Namespace files and scripts reach the tree there, and `cd /root && tar cf /fd/1 .` flattens the stack into one archive.
- **Creates at `/`** go to `#Oroot`, which is bound with `-c`; `#/` takes none.

The Linux view is built the same way: devlinux's own directories first, with `#Olinux` unioned after them at `#L`.

**With nothing on `/`,** the source is `$H9ROOT`, then the built-in root. The development tree, `.local/9front/root` beside the binary's source tree, is no longer looked for: a developer sets `$H9ROOT` or passes `--dir`. `$H9ROOT` is read as a `--url` if it has `://`, and as a `--dir` otherwise. `--builtin` on `/` alongside other sources is an ordinary member, so what `--builtin=before` and `after` do now is `--builtin` on top of or at the bottom of the stack, and `--builtin=only` is `--builtin` alone.

### Union instances

This section is [recursive-unions](recursive-unions.md)' design, which this proposal takes in.

An `#O` instance has an ordered list of members and a mode. In `cow` mode, made by `bind -c '#O' PATH`, writes copy up into memory and removes leave whiteouts, as `#O` works now. In `union` mode, made by `bind -r`, there's no memory tree: writes go to the member that holds the file, and creates go to the first member marked `-c` that has the parent directory, or fail with "mounted directory forbids creation".

- **Walks.** Each member is walked to the same relative path, in order. The first member that has the name decides what it is: a file is that member's file, and a directory is merged over every member with a directory by that name. Walks are device walks, so a member is its tree, not the mounts on it. A walk of several names costs each member one walk, so a 9P member costs one round trip.
- **Directory reads** list each name once, with the first member's entry, from a snapshot taken at open and counted against `--memory`.
- **Qids.** The instance maps each (member, qid path) to its own qid, in a table counted against `--memory`.
- **Rooted members.** A member can be rooted below the instance's top, as `--dir ./etcfix:#L/etc` needs: it's walked only for paths under that point, and merged there as any other member.
- **Limits.** At most 64 members per instance, and instances count against `#O`'s limit of 256.
- **Named instances.** `#Oroot` and `#Olinux` are the two stacks. A named instance lives until the machine ends.
- **`bind -r`** in namespace syntax (`newns.zig`, `--ns`, and `--print`) makes a union of `new` at `old`, and `-b` and `-a` add `new` on top or at the bottom of a union already there. On `#O<name>`, it makes or extends the named instance and binds nothing.
- **Guests.** A bare `#O` attach serves `clone`, which makes a `union` instance owned by the caller's machine and takes `add [-a|-b] [-c] PATH`, `del PATH`, and `cow` messages, with paths resolved in the writer's namespace. h9's fork of 9front's `bind(1)`, with `-r`, is in `#H` and bound before `/bin`. devproc prints unions as `bind -r` lines, so `ns` output replays.

### Namespace files

`--ns` lines accept the URL forms in `mount` lines, alongside `tcp!` dial strings, and accept `bind -r` and named `#O` specs. `--print` writes each flag as the lines it becomes, and every line names its sources by path or URL, never by instance number, so `--print` output replays, Linux tree and 9P settings included. A `mount` line takes the settings as trailing `key=value` words after its spec: `mount -c wss://fs.example/9p /n/fs '' header=@/mnt/term/cwd/h`.

### Removed

- `--root`, `--root-spec`, `--root-user`, `--root-header`, `--root-ca`, `--root-contained`, and `--builtin auto|only|before|after|off`. They're replaced by the flags and options above, with no aliases.
- Detecting a Linux tree by its contents. A Linux tree is mounted on `#L`.
- Looking for the development tree (`defaultRoot` in `src/main.zig`). The built-in root covers a fresh checkout, and `zig build mkroot` still makes `.local/9front/root` for `-Droot`, the demos, and the integration tests, which pass it explicitly.
- `tcp!` and `unix!` dial strings on the command line. They stay in namespace files and `mount` inside the machine.
- [recursive-unions](recursive-unions.md)' `--layer`, never built: repeated sources on `/` or `#L` do what it did.

### The device rename

devlinux becomes `#L`, and `#λ` stays an alias for it in namespace files. devlfd, `#L` now, becomes `#φ`. It's internal: h9 uses it for unix-socket mounts, and a user rarely names it.

### Machine API and the browser host

`Machine.Options` replaces `root`, `root_spec`, `root_user`, `root_headers`, `root_ca`, `root_contained`, `linux_root`, and `builtin` with:

- `mounts: []const Mount`, each a source (`.dir`, `.url`, `.archive`, `.builtin`, `.tmp`, `.fd` for a connection the embedder already holds, or `.port` on the browser host), a destination, and options. `Mount.parse` reads the flag syntax.
- `binds: []const Bind`.

The CLI fills both from its flags. On the browser host, `createMachine({ mounts, binds })` takes the same strings or objects, and a `MessagePort` source (`{ port, dst }`). `root` and `layers` are removed.

## Rationale

**Named flags, not one `--mount`.** One flag would have to work out the source's kind from its text. A host path, a URL, and a dial string overlap, `!` in dial strings needs quoting in some shells, and `wss://h:8080/x:/` is hard to split without knowing it's a URL. A flag per kind keeps each value's syntax its own, and the help groups them under Mounts.

**URLs, not dial strings.** `tcp://` and `unix://` are what Docker and most tools use, they carry a spec in the path the way h9reg already uses a WebSocket URL's path, and they leave `!` out of shell commands. Namespace files keep dial strings, since nothing there is parsed by a shell.

**Mount and bind are two flags.** A source from outside the machine and a path inside it both start with `/`. `--dir /sys/lib:/lib` and `--bind /sys/lib:/lib` mean different things, and a separate flag says which.

**Plan 9's letters for options.** `b`, `a`, `c`, and `r` are `bind(1)`'s flags and what `--print` writes, so a flag reads as the line it becomes. The long names are there for readability. `eph` is the word `--print` already shows for overlay binds, and it isn't confused with `c`.

**`#L` as a destination, not a `linux` option.** The Linux tree is a place in the namespace, and naming it as a destination lets `--bind` and namespace files reach it the same way. An option would only mark one mount.

**Removing `--root` outright.** Nobody depends on h9's flags yet. Keeping `--root` as an alias would keep its content detection and dial strings alive for compatibility no one needs.

**Removing content detection.** A tree that has both `/etc/os-release` and `/rc/bin`, or a layer with only `etc/resolv.conf`, can't be classified. Saying `#L` is one more character.

**WebSocket first for `http` URLs.** A server that speaks 9P over a WebSocket gives live, writable trees, and a static tree can't. One GET tells them apart, and a server can offer both on the same URL.

**dotfs's index for static trees, not `/.h9index`.** dotfs is a 9P extension that 9P servers can also serve, with hashes, nested indexes, and change sequences, so one index format works for HTTP and 9P alike.

**Stacks only at `/` and `#L`.** 9front relies on one-level unions elsewhere: `/dev` is `#c` with h9's console before it, and `/bin` is several trees. Making every repeated mount recursive would change what existing namespace files mean. `r` asks for it anywhere else.

**`#/` first, as 9front does.** It removes the remote lookups the report found, without asking the server for anything, and it frees trees from carrying empty mount points. The alternative, local scaffolding of empty directories bound over the tree, does the same work with a device 9front already has.

**One proposal.** The flags, URLs, stacks, and the new `/` change the same lines of the plan, and each makes sense only with the others. Splitting them would ship intermediate flags that the next part removes.

## Compatibility

- **CLI:** new `--dir`, `--url`, `--archive`, `--tmp`, and `--bind`; `--builtin` takes a destination. `--root`, `--root-spec`, `--root-user`, `--root-header`, `--root-ca`, and `--root-contained` are removed, so scripts that use them fail with exit 2 and a message naming the replacement. Exit codes are unchanged.
- **`$H9ROOT`:** still the default for `/`. A dial string in it is an error naming the URL form.
- **The development tree:** a development build of `h9` with no `$H9ROOT` runs from the built-in root instead of `.local/9front/root`. `zig build mkroot` prints the `export H9ROOT=…` line to add.
- **Schemeless URLs:** they mean `https://` or `http://` and probe for a WebSocket, not `wss://` or `ws://` directly. A WebSocket server answers the probe, so every URL that works now still works.
- **`--print`:** every plan starts with `bind '#/' /`, and the root's lines change to the stack lines above. The Linux tree's lines change from `#λ` to `#L` and `#Olinux`, and they now replay.
- **`--ns`:** files that worked before mean the same, with `#λ` as an alias. New: URLs in `mount`, settings words, `bind -r`, and named `#O` specs.
- **Root trees:** trees no longer need empty `dev`, `env`, `fd`, `net`, `proc`, or `srv`. Trees that have them still work. `/root` is the root stack, not the tree's own `/root`.
- **`Machine.Options`:** the root fields become `mounts` and `binds`, which breaks embedders. There are none outside this repository.
- **Browser host:** `createMachine`'s `root` and `layers` become `mounts`.
- **Guests:** a bare `#O` attach serves `clone` instead of failing, and `/bin/bind` is h9's fork, which behaves as 9front's without `-r`.
- **`third_party/`:** the device letter of devlfd (`devlfd-posix.c` and `devlfd-win32.c`), one character each. devroot is unchanged.
- **Other proposals:** [recursive-unions](recursive-unions.md) and [host-srv](host-srv.md) are superseded by this one. [root-auth](root-auth.md)'s `--root-auth` becomes `auth=`. [credential-helpers](credential-helpers.md)' helpers cover every `--url`. [mount-index](mount-index.md)'s `--root-index` becomes `index=`, with dotfs's format. [tilde-roots](tilde-roots.md) is unchanged and would need its own update.
- **Docs and repos:** MANUAL.md, README.md, the docs (containers, recipes, and embedding), the site, the workloads, and the READMEs of h9reg and mkroot-9front all use `--root`, and change to these flags.

## Security

- **Host access.** `--dir` adds its path to the plan's access rules, read-only unless `rw`, exactly as `--readable` and `--writable` do. Nothing a flag can't already grant becomes reachable. `--ns` runs after `#U` is masked, as now, so a namespace file still can't reach a host path a flag didn't share.
- **Network.** h9 makes `--url` connections on the host before the program starts, as it makes `--root`'s now. The probe and the index and content fetches go only to the URL's host, through the same proxy settings. A URL inside a namespace file is dialled under the network policy, as now.
- **Static trees** are read-only, and contents are checked against their index hashes, so a server or cache can't swap a file's contents unnoticed when the index is trusted. The index itself is only as trustworthy as the server and its TLS.
- **`/srv/NAME`** posts a connection the guest can mount with any spec. It's the same reach a `--url` mount gives, since the guest can already walk that mount.
- **Union instances:** as in recursive-unions. `clone`'s `add` resolves paths in the writer's own namespace, so a member is a tree the guest could already walk, and writes go through each member's device and its checks.
- **Memory.** Archives, overlays, union qid tables, and merged directory snapshots count against `--memory`.

## Done criteria

```
h9 --dir ~/9front:/ rc -c 'ls /root/rc/bin | sed 3q'
h9 --builtin --dir ./app:/ --archive ./fix.tgz:/ --rc 'cat /lib/app.conf; cd /root && tar cf /fd/1 .' > merged.tar
h9 --dir ./alpine:#L --dir ./etcfix:#L/etc sh -c 'cat /etc/resolv.conf; ls /etc | wc -l'
h9 --url tcp://127.0.0.1:5640:/ --rc 'ls /'
h9 --url unix:///tmp/fs.sock:/n/fs:spec=main --rc 'ls /n/fs'
h9 --url https://roots.example/9front:/ --rc 'echo hi'
h9 --url ws://127.0.0.1:8564/alpine:3.20:#L sh -c 'cat /etc/alpine-release'
h9 --dir ./data:/app/data:rw --tmp /scratch --bind /app/data/bin:/bin:b --rc 'mydata-tool'
```

Integration cases:

- [ ] `test "--dir on / binds a host tree behind #/ [mounts]"`
- [ ] `test "a 9P root is never walked for dev, env, fd, proc, srv, or net [mounts]"`
- [ ] `test "/root is the root stack without the namespace's binds [mounts]"`
- [ ] `test "a bare tree without mount points runs rc [mounts]"`
- [ ] `test "sources on / stack, later on top, and merge at every depth [mounts]"`
- [ ] `test "b and a place a member on top of or at the bottom of a stack [mounts]"`
- [ ] `test "--builtin is a member of the / stack [mounts]"`
- [ ] `test "--dir on #L makes a Linux tree, and /dev stays devlinux's [mounts]"`
- [ ] `test "--dir on #L/etc adds a member under the Linux tree's /etc [mounts]"`
- [ ] `test "--dir on another path replaces it, and r merges [mounts]"`
- [ ] `test "a missing DST is made in the root's overlay [mounts]"`
- [ ] `test "a missing DST under a read-only root is exit 125 [mounts]"`
- [ ] `test "--url tcp:// and unix:// mount 9P, with spec from the path or spec= [mounts]"`
- [ ] `test "--url http:// upgrades to a WebSocket when the server answers 101 [mounts]"`
- [ ] `test "--url http:// falls back to a static dotfs tree [mounts]"`
- [ ] `test "a static tree reads by Range and fails a read on a hash mismatch [mounts]"`
- [ ] `test "a static tree loads a nested index on first use [mounts]"`
- [ ] `test "a 9P server's .fs/index answers walks without the server [mounts]"`
- [ ] `test "--url to /srv/NAME posts without mounting [mounts]"`
- [ ] `test "--archive unpacks into memory, counted against --memory [mounts]"`
- [ ] `test "--tmp makes an empty writable tree [mounts]"`
- [ ] `test "--bind runs after every mount, in order [mounts]"`
- [ ] `test "the long src= form takes values with colons and quoted commas [mounts]"`
- [ ] `test "conflicting options are a usage error [mounts]"`
- [ ] `test "--write=none rejects rw, eph, and 9P mounts [mounts]"`
- [ ] `test "--dir rw writes through to the host, and ro denies [mounts]"`
- [ ] `test "--root and --root-spec fail with exit 2 naming the replacement [mounts]"`
- [ ] `test "a development build without $H9ROOT runs from the built-in root [mounts]"`
- [ ] `test "--print output with a Linux tree and 9P settings replays with --ns [mounts]"`
- [ ] `test "#λ is an alias for #L in namespace files [mounts]"`
- [ ] `test "bind -r merges directories below the bind point [mounts]"`
- [ ] `test "bind -r: creates go to the first -c member with the parent [mounts]"`
- [ ] `test "bind -r: removing an upper file uncovers the lower one [mounts]"`
- [ ] `test "bind -c '#O' over a union copies up and whites out [mounts]"`
- [ ] `test "ns prints unions as bind -r lines that replay [mounts]"`
- [ ] `test "a guest can't attach another machine's union [mounts]"`

Browser host:

- [ ] `test('createMachine mounts an archive stack and a ws:// URL [mounts]')`
- [ ] `test('createMachine mounts a static tree over fetch [mounts]')`

## Implementation

1. `#O` members, `union` mode, the qid table, and named instances, with kernel tests beside the existing `#O` ones.
2. `/` built as `#/` with `#Oroot` behind it and at `/root`, and the Linux tree as `#Olinux` at `#L`. Rename devlinux to `#L` and devlfd to `#φ`. Plan lines and `--print`.
3. The mount model in `policy.zig` and `Machine.Options.mounts` and `binds`, with `Mount.parse` for the flag syntax and its long form, and the CLI flags. Remove `--root` and its family, content detection, and the development-tree lookup.
4. `--url` with `tcp://`, `unix://`, `ws://`, and `wss://`, posting to `/srv/NAME`, and URLs and settings words in namespace-file `mount` lines.
5. The probe, and static dotfs trees as a host-side 9P server, with the hash cache. Indexes on 9P servers and `index=`.
6. `--archive` and `--tmp` natively, and `createMachine({ mounts, binds })` on the browser host.
7. `bind -r` in namespace files, the `clone` control tree, the forked `bind`, and devproc's `bind -r` lines.
8. MANUAL.md, README.md, the docs, the site, the workloads, and the h9reg and mkroot-9front READMEs. Mark recursive-unions and host-srv superseded. SPEC.md once built.

## Open issues

- **`/root` versus a tree's own `/root`.** A tree that ships files in `/root` loses them behind the stack's bind. 9front trees have it empty. Linux trees have root's home there, but the Linux view isn't affected, since `#L` is built separately.
- **`ls /`** reads `#/` and the stack, so `bin`, `dev`, and the rest can appear twice, as on 9front. h9 could filter `#/`'s names that the tree also has, at the cost of differing from 9front.
- **Removing one layer.** `unmount` on a stack removes the whole bind. A forked `unmount` could call `del` when `new` is a member.
- **`#H/over` precedence.** Binding h9's `bind` before the root's `/bin` is the first time h9 shadows a root command. It may want to be part of `--builtin` on top of the stack.
- **dotfs's static profile** isn't written in dotfs itself yet: the path mapping, `Accept-Encoding` for zstd, and Range reads. It belongs there, so other clients serve and read static trees the same way.
- **`https://` archives.** `--archive` could take a URL, as the browser host's `layers` do now.
