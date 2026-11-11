---
issue: 22
slug: dotl
title: 9P2000.L and ZeroFS
status: accepted
created: 2026-11-05
authors: [progrium]
depends: [devsrv, ninep-roots, serve, guest-tools]
areas: [cli, kern, sandbox]
branch: [dotl]
---

# Proposal: 9P2000.L and ZeroFS

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 mounts servers that speak 9P2000.L, Linux's dialect of 9P, and ZeroFS's extension of it, `9P2000.L.Z`. It also serves its machine's namespace to Linux clients in 9P2000.L, through [serve](serve.md)'s listeners. Both directions go through one translator in Zig, between 9P2000, which is all devmnt and exportfs speak, and 9P2000.L on the wire. The translator negotiates the dialect itself: it offers `9P2000.L.Z`, takes `9P2000.L`, and passes plain 9P2000 through untouched. So `--root`, namespace files, and the guest's `mount` reach a .L server the way they reach a 9front one, with no new flag. A new device, `#ℓ`, carries the translator into the kernel, as devhstream carries a WebSocket in [websocket-9p](websocket-9p.md). With ZeroFS's extension, the translator also reconnects a dropped connection under devmnt without failing open files, which plain 9P can't do.

The [Linux personality](linux-personality.md) doesn't provide any of this, and this proposal doesn't depend on it. They share one module: the mapping between Plan 9's `Dir` and error strings and Linux's `stat` and errno, which both need. They also resolve symlinks by the same rule, from [symlinks-in-root](symlinks-in-root.md). The personality gains two things on top: `mount -t 9p` for Linux programs, and, once its threads and networking are built, running ZeroFS's own server inside a machine.

## Background

### 9P2000.L

9P2000.L is the dialect Linux's v9fs speaks (`mount -t 9p -o version=9p2000.L`), and the one most 9P servers outside Plan 9 serve: diod, QEMU's virtfs, gVisor's gofer, crosvm, and ZeroFS. It keeps 9P2000's framing and a few of its messages (`Tversion`, `Tattach`, `Twalk`, `Tread`, `Twrite`, `Tclunk`, `Tflush`) and replaces the rest with Linux's VFS operations:

| 9P2000 | 9P2000.L |
| --- | --- |
| `Topen`, `Tcreate` | `Tlopen`, `Tlcreate`, `Tmkdir`, `Tsymlink`, `Tmknod`, `Tlink` with Linux open flags and modes |
| `Tstat`, `Twstat` (a `Dir`, with names for users) | `Tgetattr`, `Tsetattr` (a Linux `stat`, with numeric uid and gid) |
| A directory `Tread` returns `Dir` records | `Treaddir` returns `qid offset type name` entries with opaque offsets |
| `Tremove`, rename by `Twstat` | `Tunlinkat`, `Trenameat` on a directory fid and a name |
| `Rerror` with a string | `Rlerror` with an errno |
| none | `Treadlink`, `Tlock`, `Tgetlock`, `Txattrwalk`, `Tstatfs`, `Tfsync` |

`Tattach` gains `n_uname`, a numeric uid.

### ZeroFS's extension

ZeroFS (zerofs.net) is a file system on object storage that serves NFS, NBD, and 9P. Its 9P server and client share the `ninep-proto` crate, which defines `9P2000.L.Z`, negotiated by `Tversion` like any dialect. Its additions, from `wire_types.rs` and `slice_codec.rs` in ninep-proto 0.4.0:

- **Compound reads.** `Twalkgetattr` (252) walks and returns the destination's attributes. `Treaddirattr` (254) reads directory entries with full attributes. `Tlopenat` (236) opens a copy of a fid, and `Tlopenatread` (230) does that and reads from offset 0 in one round trip.
- **Creates that return attributes.** `Tlcreateattr`, `Tmkdirattr`, `Tsymlinkattr`, `Tmknodattr`, `Tlinkattr`, and `Tsetattrattr` (238 to 249) return the post-operation `stat`.
- **A mutation envelope.** Once `9P2000.L.Z` is negotiated, every mutating request (`Twrite`, `Tsetattrattr`, the creates, `Trenameat`, `Tunlinkat`, `Tfallocate`) carries `op_id[16] flags[1] origin_writer_epoch[8]` after the tag. The server remembers results by `op_id` for 150 seconds, and a client may resend a mutation with the same `op_id` and the retry flag for up to 120 seconds, so a resent write after a reconnect is applied once.
- **Reconnect.** `Trebind` (250) binds a fresh fid on a new connection to a known inode, by the `qid.path` the old connection returned, with a flag that replays an open. A client can rebuild every fid after a reconnect.
- **Durability.** `Tgetlineage` (233) returns a lineage token and an HA writer epoch, and `Tfsyncdur` (232) is a fsync that also verifies that acknowledged writes survived a failover. HA servers answer `ENOTLEADER` when they aren't the writer.
- `Tfallocate` (228), and a `SETATTR_ATIME_ACCESS` bit.

ZeroFS doesn't send `Tremove`; removal is `Tunlinkat`. The crate also defines plain `9P2000.L`, which Linux's v9fs uses against the same server.

### h9 today

- **devmnt** is drawterm's 9P2000 client. `mntversion` sends `9P2000` and refuses a reply that doesn't start with it, and the rest of devmnt speaks only 9P2000's messages. So a .L server can't be mounted, at the root or anywhere else.
- **Mounts** come from [ninep-roots](ninep-roots.md) (`--root tcp!…`, `unix!…`), [websocket-9p](websocket-9p.md) (`ws://`, `wss://`, and devhstream), namespace files, and [devsrv](devsrv.md)'s `mount` syscall in the guest. All of them end in devmnt.
- **Serving** is [serve](serve.md)'s: `--serve` listens on unix, TCP, and WebSocket addresses and gives each connection an `exportfs` of the machine's namespace, in 9P2000. Before exportfs, the client's first `Tversion` passes through a dialect slot, which serve leaves empty.
- **The Linux personality** (draft) translates Linux syscalls onto drawterm's kernel. Its file calls build a Linux `stat` from a `Dir`, map users to numbers through the Linux root's `/etc/passwd`, and map error strings to errno in "one place, tested on its own". [symlinks-in-root](symlinks-in-root.md) (draft) resolves symlinks inside a bound tree, relative to its top, for the personality's Linux root. Those are most of what a .L translator needs. But it runs Linux *programs*: it has no `mount` in its table, Linux's 9P client is v9fs in the Linux kernel, and anything a Linux program serves on a socket is still .L bytes that devmnt can't read.

## Proposal

### The translator

`src/dotl/` is a Zig translator with two sides:

- **Client side** (`client.zig`): reads 9P2000 T-messages from devmnt, writes .L or .L.Z T-messages to the server, and turns the replies back into 9P2000 R-messages.
- **Server side** (`server.zig`): reads .L T-messages from a Linux client, writes 9P2000 T-messages to `exportfs`, and turns the replies back.

Each is a state machine over byte buffers, with no I/O of its own: bytes in on one end, bytes out on the other, plus a timer for retries. So it's tested with recorded conversations and no kernel, and both sides share the encoding in `src/dotl/wire.zig` and the mappings in `src/dotl/attr.zig` (see Shared with the Linux personality).

**Negotiation, client side.** devmnt's `Tversion` is answered locally with `9P2000` and the smaller `msize`. The translator sends its own `Tversion` offering `9P2000.L.Z`, and goes by the reply, as version(5) lets a server pick a lower version:

| Server replies | Translator |
| --- | --- |
| `9P2000.L.Z` | Translates, using the extension |
| `9P2000.L` | Translates, with standard messages only |
| `9P2000` | Passes bytes through both ways unchanged. A 9front server answers this way. |
| `unknown`, or anything else | Fails the mount: "server speaks unknown 9P version X" |

Passthrough costs a copy and nothing else, so every 9P mount goes through the translator, and a .L server is reached by the same dial string as a 9front one.

**Mapping, client side.**

| devmnt sends | Translator sends |
| --- | --- |
| `Tattach` | `Tattach` with `uname` and `n_uname` from the user map |
| `Twalk` | `Twalk`; with .L.Z, `Twalkgetattr` to fill an attribute cache. A walk onto a symlink is followed (see Symlinks). |
| `Topen` | `Tlopen` (`Tlopenat` with .L.Z). `OREAD`, `OWRITE`, `ORDWR`, `OTRUNC` map to Linux flags; `ORCLOSE` is kept in the translator and becomes a `Tunlinkat` at clunk. `OEXEC` is `O_RDONLY`. |
| `Tcreate` | `Tlcreate`, or `Tmkdir` and a `Tlopen` for `DMDIR`. `DMAPPEND`, `DMEXCL`, and `DMTMP` are dropped. |
| `Tread` on a file | `Tread` |
| `Tread` on a directory | `Treaddir` and a `Tgetattr` per entry, or one `Treaddirattr` with .L.Z, packed into `Dir` records. devmnt reads directories sequentially, so the translator keeps one cookie per fid. |
| `Twrite` | `Twrite`, in an envelope with .L.Z |
| `Tstat` | `Tgetattr`, built into a `Dir` |
| `Twstat` | `Trenameat` for a name change, then `Tsetattr` for mode, length, and mtime. The rename goes first because a server refuses it most often (an existing name, a busy file), and a refused rename then leaves the file untouched. If the `Tsetattr` fails after a rename, the error is returned and the rename stands: two messages can't keep wstat(5)'s all-or-nothing rule. A wstat with every field "don't touch", which stat(5) defines as a request to commit to stable storage, becomes `Tfsync` (`Tfsyncdur` with .L.Z). |
| `Tremove` | `Tunlinkat` on the fid's parent, with `AT_REMOVEDIR` for a directory, then a clunk |
| `Tclunk`, `Tflush` | The same. A `Tflush` of a request that became several flushes all of them. |

The translator keeps each fid's path from its attach fid, so it can walk a parent fid for `Tunlinkat` and `Trenameat`. It allocates the server-side fids and tags itself, since one devmnt request can become several.

**`Dir` from a Linux `stat`:** `qid` as is, the mode's permission bits with `DMDIR` for `S_IFDIR`, `length` from `size`, `atime` and `mtime` in seconds, `uid` and `gid` named through the user map, and `muid` the same as `uid`. A device node, FIFO, or socket is shown as a zero-length file that fails to open ("not a regular file").

**Errors:** `Rlerror` becomes `Rerror` with the string `attr.zig`'s table gives for that errno, the same table the Linux personality reads the other way: `ENOENT` is "file does not exist", `EACCES` is "permission denied", and an unknown errno is "errno N".

**Symlinks.** Plan 9 has no symlinks and devmnt can't show one. The translator follows a link during a walk, with `Treadlink`, resolving it inside the mount by [symlinks-in-root](symlinks-in-root.md)'s rule for contained trees: an absolute target is relative to the attach root, `..` stops there, and more than 40 links in one walk is "too many symbolic links". A link to a missing target is "file does not exist". A directory read lists a link with its target's `Dir`, or omits it when the target is missing.

**The user map.** .L carries numbers, 9P2000 names. The map is `--user-map FILE`, in `/etc/passwd` format, read once at start. Without one, the machine's user is `n_uname` the host user's uid (`getuid()`), or 1000 on Windows, which has none, and any other number N is the name "N" and back. The translator never sends 0 unless the map says so (see Security).

This map is separate from the Linux personality's, which makes the machine's user 0 inside a Linux root. The two compose rather than conflict: the translator names the server's uid as the machine's user, and the personality shows that user as 0 to Linux programs. So a Linux root doesn't change what goes on the wire. `attr.zig` shares the `/etc/passwd` parsing between them, not the policy.

### Using ZeroFS's extension

#### Round trips

devmnt sends one request per operation and waits for each, so the translator, not devmnt, is where ZeroFS's compound messages save round trips. The translator talks to devmnt in the same process, so a request it answers locally costs a copy and no network.

| Operation | devmnt sends | Round trips to the server, .L | With .L.Z |
| --- | --- | --- | --- |
| List a directory of N entries | `Tread`s on the directory | 1 + N (`Treaddir`, then `Tgetattr` each) | 1 per `msize` of entries (`Treaddirattr`) |
| Walk, then stat (`ls -l` of a path, `test -e`) | `Twalk`, `Tstat` | 2 | 1: `Twalkgetattr`, and the `Tstat` is answered from its result |
| Open and read a small file (exec, reading a config) | `Twalk`, `Topen`, `Tread` | 3 | 2: `Tlopenatread` prefetches up to one `msize`, and the first `Tread` at offset 0 is answered from it |
| Create a file and stat it | `Tcreate`, `Tstat` | 2 | 1: `Tlcreateattr` |
| Read a large file sequentially | `Tread`s of at most 32 KiB, devmnt's `MAXRPC` | one per 32 KiB | one per upstream `msize` (up to 10 MiB with ZeroFS), with read-ahead (below) |

Attributes the translator holds from a compound reply answer only the next `Tstat` on the same fid, or on a fid walked from it in the same walk. A mutation through any fid drops them. So the cache never answers from state older than the client's own last request.

**Read-ahead and msize.** devmnt caps its own `msize` at 32 KiB, which no flag changes without patching the vendored tree. Upstream, the translator negotiates the largest `msize` the server allows (capped at 1 MiB by default), and when a fid's reads are sequential it reads one upstream `msize` ahead and serves devmnt's 32 KiB reads from that buffer. A seek, a write, or a mutation on the file drops the buffer. Read-ahead works with plain .L too. Writes aren't coalesced, because a write's `Rwrite` count is the guest's answer.

**What isn't kept.** Each devmnt request still waits for the one before it in the same process, so latency per operation, not bandwidth, bounds a chatty program. Pipelining across a process's requests would need devmnt changes and is out of scope. On the server side, `--serve` answers `.L.Z` with `.L`, so a ZeroFS client mounting h9 gets none of this (see Rationale).

#### Reconnect and HA

Besides fewer round trips, `9P2000.L.Z` gives two things plain 9P has no answer for.

- **Reconnect.** When the connection drops, the translator redials the same address (TCP, unix socket, or WebSocket), negotiates again, rebinds every live fid with `Trebind` by its inode and attach root, replays the open of each opened one, and resends each unanswered mutation with its original `op_id` and the retry flag. A replayed open drops `O_TRUNC`, `O_CREAT`, and `O_EXCL`, so a reconnect never truncates or recreates a file the guest is already writing, and a fid's `ORCLOSE` survives the rebind, since the translator holds it. Every read-ahead buffer and cached attribute is dropped, because the server may have changed while the connection was down. devmnt sees slow replies, not a hangup. It retries for up to 120 seconds, the extension's retry horizon, then fails outstanding requests with "i/o on hungup channel" as before. A note interrupts a waiting request as usual.
- **`ENOTLEADER`** from an HA server is treated as a drop and handled the same way, so a failover behind one address is invisible to the guest. For HA servers without one address in front, `dial` takes several addresses separated by commas: a failed dial or an `ENOTLEADER` moves the reconnect to the next, round the list until the 120 seconds run out. Each is dialed through the guest's `/net`, under net-policy. Discovering a new leader from the server isn't done (see Rationale).

Without the extension, a drop is a hangup, as for any 9P mount. websocket-9p's "No reconnect" stands for 9P2000 and .L servers.

### `#ℓ`, the translator in the kernel

`src/kern/devdotl.c` serves conversations laid out like devip's:

```text
/net/dotl/clone
/net/dotl/N/ctl
/net/dotl/N/data
/net/dotl/N/status
```

- **`ctl`** takes `fd N` (use the caller's fd N as the server connection, with no reconnect, since the translator can't redial it), or `dial ADDR[,ADDR…]` (dial `tcp!…`, `unix!…`, `ws://`, or `wss://` through the caller's own `/net`, so [net-policy](net-policy.md) applies as for any guest dial). `version 9P2000.L` caps what's offered, for servers that answer `9P2000.L.Z` wrongly.
- **`data`** is the 9P2000 side: what devmnt mounts.
- **`status`** reads the negotiated dialect, `9P2000.L.Z reconnects 2` for example.

It follows devhstream's pattern and the seam rules: a kproc per conversation reads the server connection, the translator is called through leaves that take and return bytes and never raise, and a guest reading `data` sleeps on a Rendez. The namespace builder binds it with `bind -a '#ℓ' /net`.

**Roots and namespace files** use it without being asked. ninep-roots' and websocket-9p's connections are put through a conversation before devmnt mounts them, so `--root tcp!zerofs.example!5564` works, and `mount 'tcp!zerofs.example!5564' /n/z` does in a namespace file.

**In the guest,** `/bin/dotlfs`, an rc script that [guest-tools](guest-tools.md) ships in the guest's `/bin`, does the same: `dotlfs tcp!zerofs.example!5564 /n/z` writes `dial` to a new conversation and mounts its `data`, through devsrv's `mount`.

### Serving 9P2000.L

dotl fills [serve](serve.md)'s dialect slot with the translator's server side. By the client's `Tversion`:

- `9P2000` passes through, so a 9front or h9 client mounts it directly.
- `9P2000.L` translates, so `mount -t 9p -o trans=unix,version=9p2000.L /run/h9.sock /mnt` works on Linux, and so do diod's and QEMU's clients.
- `9P2000.L.Z` is answered with `9P2000.L`, as version(5) allows. A client that accepts it gets plain .L; one that refuses it fails to mount, which is no worse than not serving `.L.Z` at all (see Rationale).

It applies on every serve listener, WebSocket included.

**Mapping, server side**, the reverse of the client's: `Tgetattr` is a `Tstat`, `Treaddir` reads the whole directory once into a listing kept on the fid and hands out entry indexes into it as offsets, so a large directory isn't re-read from the start for each call; a `Treaddir` at offset 0 or any mutation through the connection drops the listing, `Tlopen` is `Topen`, `Tsetattr` is a `Twstat`, `Tunlinkat` walks and removes, `Trenameat` within a directory is a `Twstat` of the name (across directories it's `EXDEV`, as Plan 9 renames only within one), `Tfsync` is the null `Twstat`, and `Tstatfs` reports fixed sizes. `Tsymlink`, `Tmknod`, `Tlink`, and xattrs are `EOPNOTSUPP`. `Tlock` and `Tgetlock` are served from a byte-range lock table in the translator, advisory and per `--serve` address. Error strings become errno through the shared table.

Every client acts as the machine's user, as serve says. `n_uname` is mapped to a name only for the `uid` it sees in `stat`.

`--print`'s `serve` heading notes `9P2000.L` beside each listener.

### Shared with the Linux personality

`src/dotl/attr.zig` holds the mappings both need, created by whichever of this proposal and [linux-personality](linux-personality.md) is built first, and used by the other: errno to error string and back, `Dir` to `stat` and back, mode bits, and the user map. Neither proposal depends on the other for it.

The personality then gets these from this proposal, each in its own stage and not required here:

- **Linux programs see .L mounts** through devmnt, like any mount, with symlinks already followed. So `readlinkat` and `lstat`-style calls still report links, the translator keeps the unresolved target of the last link it followed for each fid, as devfs does for [symlinks-in-root](symlinks-in-root.md). That proposal's `h9_fs_readlink` leaf becomes `h9_readlink(Chan*)`, which answers from devfs for a devfs chan and from the translator for a chan mounted over a `#ℓ` conversation. Neither a `ctl` query, since the personality holds a path and not a conversation, nor a `Dir` extension, which would break 9P2000, is needed. Creating links isn't provided: `symlinkat` isn't in the personality's table, and devmnt has no message to carry it.
- **Byte-range locks stay in the machine.** The personality's `fcntl(F_SETLK)` locks are local to the machine for every file, .L mounts included, and the client side never sends `Tlock`. Plan 9 programs never ask for them, and locks that coordinate several machines through one server would be a proposal of their own.
- **`mount(2)` for Linux programs.** The personality stubs `mount` as `-EPERM`; this adds `mount` with `-t 9p` and `trans=tcp`, `trans=unix`, or `trans=fd`, served by opening a `#ℓ` conversation and calling `sysmount` on its `data`. Busybox's `mount -t 9p` then works in a machine.
- **ZeroFS in a machine.** Once the personality runs tokio programs, with [linux-threads](linux-threads.md) and [linux-net](linux-net.md), `zerofs` itself runs as a Linux process, serves on a socket in the machine, and is mounted through `#ℓ`. That's a demo of both proposals, not a requirement of this one.

## Rationale

**Is the Linux personality the way to get .L?** No. It translates Linux syscalls, and 9P is below them: Linux's 9P client is in the Linux kernel, which the personality replaces with drawterm's, and drawterm's client is devmnt. Linux userspace 9P servers would run under it, but their bytes still need translating before devmnt can mount them, and nothing in the personality serves the machine's namespace to Linux clients. What the personality does share with .L support is semantics, the `stat`, errno, uid, and symlink mappings, so that's what's shared.

**Teaching devmnt 9P2000.L.** devmnt's channel operations (`mntopen`, `mntstat`, `mntwalk`, `mntread` on directories) would each need a .L path, in the vendored tree, in C, and the reconnect logic would sit under `waserror`. A translator in front of it is project-owned Zig, tested without a kernel, and serves the other direction with the same code. It costs a copy per message, and an extra round trip where 9P2000 has no compound to match (a directory read without .L.Z).

**A translator as a 9front program in the guest,** which would also run on real 9front. It reads one fd and posts to `/srv`, costing two process switches per message, and it can't make host-side connections for roots before the first process exists. The Zig translator could be wrapped as one later if real 9front wants it.

**9P2000.u.** It adds symlinks and numeric ids to 9P2000, but devmnt doesn't speak it either, Linux defaults to .L, and ZeroFS doesn't serve it.

**Always going through the translator.** Negotiation picks passthrough for 9P2000 servers, so no flag says which dialect a server speaks, and a server can change dialect without the guest's configuration changing.

**Serving `9P2000.L.Z`.** Its compound messages and envelope would be easy to serve, but `Trebind` needs a fid by inode number, and 9P2000 can't open by `qid.path`. A table from `qid.path` to the last path the translator saw goes stale when a file is renamed, including by another client of the same exportfs, and rebinding to the wrong file is a silent correctness bug, worse than a hangup. Serving `.L.Z` needs open by qid in exportfs, and is a proposal of its own.

**Discovering an HA leader.** ZeroFS's client learns the new writer from the cluster, but how isn't documented outside its source and may change. A list of addresses covers the common case without depending on it, and a single address in front of the cluster covers the rest.

**Serving through serve.** The listeners, the exportfs-per-connection model, and their policy aren't about the dialect, and WebSocket serving needed the same ones, so they're [serve](serve.md)'s. dotl adds only what .L needs: the translator in serve's dialect slot.

## Compatibility

- **CLI:** new `--user-map FILE`. `--serve` listeners also answer 9P2000.L clients. ninep-roots' and websocket-9p's dial strings now also reach .L servers. No exit code changes; a server with an unknown dialect is exit 125 like any failed root.
- **`Machine.Options`** gains `user_map: ?[]const u8`. Without it, the machine's user is the host uid on the wire.
- **Behaviour of 9P2000 mounts:** unchanged, through passthrough. `status` shows `9P2000`.
- **The root tree:** unchanged. `/bin/dotlfs` comes from [guest-tools](guest-tools.md)' `#H`.
- **`third_party/`:** none. devdotl and the translator are project-owned.

## Security

- **New guest reach.** A guest can mount .L servers it can already dial: `dial` goes through the guest's own `/net`, so `--net` and `--net-allow` apply. The translator makes no connection the guest couldn't, except reconnects to an address already allowed.
- **Identity sent to a .L server.** `n_uname` is a claim the server may trust: diod, or virtfs in passthrough mode running as root, gives uid 0 root's access to its files. The translator sends the host user's uid by default and never 0 unless `--user-map` says so, and `--user-map` is the only way to choose what's sent. The guest can't set it.
- **A hostile .L server** can send anything. Replies are bounds-checked in `wire.zig`, symlink resolution never leaves the attach root and stops at 40 links, and directory reads are capped by `msize`. A server that sends a reply for an unknown tag fails the connection.
- **Serving** is covered by [serve](serve.md)'s Security: a .L client reaches what a 9P2000 client of the same listener does, through the same exportfs. The translator adds no reach, only a lock table bounded per listener.
- **Fuzzing.** Both sides of the translator take hostile input, so each gets a fuzz target over recorded conversations.

## Done criteria

Integration cases tagged `[dotl]`. The .L server is diod, or failing that the `ninep-proto` crate's test server, fetched by `scripts/fetch.sh` at a pinned release; the .L.Z server is `zerofs` with a local-file backend.

- [x] `test "a 9P2000.L root lists, reads, writes and removes [dotl]"`
- [x] `test "a 9P2000 root goes through the translator unchanged [dotl]"`
- [x] `test "a symlink in a .L mount is followed and can't leave the mount [dotl]"`
- [x] `test "Rlerror errnos become 9front error strings [dotl]"`
- [x] `test "the guest mounts a .L server with dotlfs, under the network policy [dotl]"`
- [ ] `test "a .L.Z root survives the server restarting mid-write [dotl]"`
- [ ] `test "a .L.Z reconnect doesn't truncate a file opened with OTRUNC [dotl]"`
- [x] `test "a .L root attaches as the host uid, not 0, without --user-map [dotl]"`
- [ ] `test "Linux v9fs mounts --serve over a unix socket [dotl]"` (Linux only, in the `linux-kvm` VM, as root)
- [x] `test "a .L client of --serve under --write=none gets EROFS [dotl]"`

Demos: `h9 --root tcp!localhost!5564 ls /` on a `zerofs` serving a 9front tree. `h9 --serve unix!/tmp/h9.sock rc` then, in another shell, `mount -t 9p -o trans=unix,version=9p2000.L /tmp/h9.sock /mnt && ls /mnt/bin`.

## Implementation

1. `src/dotl/wire.zig` and `attr.zig`: encoding for 9P2000, .L, and .L.Z, the errno table, the user map. Unit tests and fuzz targets.
2. The client side with plain .L, and devdotl. `.L` roots, and `dotlfs` in `src/guest/bin`.
3. Passthrough for 9P2000, and routing ninep-roots' and websocket-9p's connections through `#ℓ`.
4. `.L.Z`: the compound messages, envelopes, `Trebind` reconnect.
5. The server side, in [serve](serve.md)'s dialect slot.
6. In the Linux personality, once it's built: `mount -t 9p`, and `h9_readlink(Chan*)` answering from the translator's last link target. SPEC.md gets a "9P dialects" paragraph under Filesystem.

## Updates

- 2026-11-11: Stages 1 to 5 of Implementation (the translator, `#ℓ`, `dotlfs`, .L and .L.Z roots, reconnect, read-ahead, the compound requests, and serving .L) reached main before this proposal was tracked, with their cases run against the in-memory server in `src/dotl/testserver.zig`. The `dotl` branch picks up from there.
- 2026-11-11: Run against diod 1.0.24, the translator had five bugs the in-memory server didn't catch, now fixed. diod answers a `Tversion` of `9P2000.L.Z` with `Rlerror` (EIO), which failed the mount. The translator's `Tversion` used tag 0, not `NOTAG`. `Treaddir` asked for `msize` less 11, more than diod's limit of `msize` less 24. diod has no `Tunlinkat` or `Trenameat`, so the translator falls back to `Tremove` and `Trename` on `EOPNOTSUPP`, as Linux's v9fs does. And a .L server applies no create(5) permission rule, so every file rc made was 0666; the translator now applies it against the directory's mode. diod comes from `scripts/fetch.sh diod`, which unpacks Ubuntu 24.04's package at pinned hashes rather than building a pinned release, and its cases skip off x86\_64 Linux. The in-memory server's cases stay, renamed, since they cover .L.Z and run on every host.
- 2026-11-11: Where what's built differs from the body. A server that answers `9P2000.L.Z` with `unknown` or an error is offered `9P2000.L`, rather than failing the mount, since diod and other .L servers do one or the other. `#ℓ`'s `dial` takes `tcp!` addresses, and `unix!` paths only when h9 dials a root itself, but not `ws://` or `wss://`: a WebSocket root or namespace-file mount is connected by h9 and handed over with `fd`, so it doesn't reconnect, and `dotlfs` can't dial a WebSocket. A namespace file's `mount` of a `tcp!` dial string goes through `#ℓ`'s `dial`, under the network policy, as `dotlfs` does.
- 2026-11-11: Stage 6, the Linux personality's `mount -t 9p` and `h9_readlink(Chan*)` answering from the translator, isn't built. It isn't among the Done criteria and can follow in its own PR.
