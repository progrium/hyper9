# Roots, 9P, and serving

This describes, as built, what a root can be, the 9P dialects h9 speaks to file servers, and how a machine serves its own namespace over 9P. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Root filesystem](#root-filesystem)
- [9P dialects](#9p-dialects)
- [Serving](#serving)
  - [Listeners](#listeners)
  - [Streams](#streams)
  - [9P2000.L clients](#9p2000l-clients)
  - [The server Proc](#the-server-proc)
  - [Process counts](#process-counts)
  - [The plan](#the-plan)

## Root filesystem

The root is either a directory holding an extracted 9front root, served through `#U` (devfs-posix or devfs-win32), which is the fastest path, with no 9P round trips; or a 9P server ([ninep-roots](../design/ninep-roots.md)), named by `--root tcp!host!port` (`tcp!host` means port 564), `unix!path`, the path of a unix socket, or a `ws://` or `wss://` URL.

A value that isn't an existing path and is shaped like `host[:port][/path]` (a dotted host, a bracketed address, a port, or `localhost`, and nothing starting with `.`, `/`, `~`, or `-` or containing `\`, `!`, `@`, or whitespace) is a URL without its scheme ([schemeless-roots](../design/schemeless-roots.md)): `ws://` for `localhost`, `127.0.0.0/8`, and `[::1]`, and `wss://` otherwise, as `cli.schemelessRoot` reads it.

The path is tried first, so a directory named like a host stays a directory, and when such a root can't be reached h9 says it read the value as a URL.

h9 connects to a 9P root before the program runs:

- A TCP root is dialed through devip by device path (`#I/cs` and `#I/tcp/clone`), outside the network policy, since h9 makes the connection and the guest can't dial anything through it.
- A unix socket root is connected on the host and wrapped as a channel with devlfd's `lfdchan` (`src/kern/rootdial.c`), on POSIX hosts only.
- A `ws://` or `wss://` root is connected by `src/hstream.zig` (TCP, TLS, the HTTP proxy if one applies, and the handshake), and its stream's channel comes from devhstream.

The connection is posted on the machine's `/srv` board as `root`, which holds it for the machine's life, and `#s/root` is mounted at `/` with no auth fd and `--root-spec` as the attach name. devmnt sends the calling process's user as the attach uname, so the first Proc takes on `--root-user` for the mount when one is given. Everything else is bound over the mount as over a host tree.

Each connection goes through a `#ℓ` conversation before it's posted (see [9P dialects](#9p-dialects)), so the server can speak 9P2000 or 9P2000.L; a TCP root, and a unix one whose path has no comma, is dialed by the conversation itself, so it can be dialed again. A refused connection, a failed `Tversion` or `Tattach` (a server that wants authentication, or one that speaks an unknown dialect) is exit 125 with the server's error; a hangup later fails file operations as devmnt does, unless a 9P2000.L.Z server's connection is resumed. Disk images aren't supported ([image-roots](../design/image-roots.md) was declined).

## 9P dialects

Every 9P connection h9 mounts, from a TCP, unix socket, or WebSocket root, a namespace file's `mount`, or the guest's `dotlfs`, goes through a `#ℓ` conversation's client side before devmnt sees it ([dotl](../design/dotl.md)). The translator answers devmnt's `Tversion` with `9P2000` itself and sends its own, with tag `NOTAG`, offering `9P2000.L.Z` at an `msize` of up to 1 MiB:

- `9P2000.L.Z` or `9P2000.L` translates, `.L.Z` with ZeroFS's extension.
- `9P2000` passes bytes through both ways unchanged, so a 9front server costs a copy.
- `unknown`, or an `Rlerror` (diod's answer), to the `.L.Z` offer gets an offer of `9P2000.L`; anything else fails the mount with "server speaks unknown 9P version X".

Translating, the client side allocates the server's fids and tags, since one devmnt request can become several, and keeps each fid's path from its attach root. `Topen` is `Tlopen`, with `ORCLOSE` kept in the translator and done at clunk. `Tcreate` is `Tlcreate`, or `Tmkdir` then a walk and `Tlopen` for a directory, with the mode create(5)'s rule gives against the directory's (a .L server applies none). A create of an existing name without `DMEXCL` opens it truncated. Directory reads are `Treaddir` and a `Tgetattr` per entry, packed into `Dir`s. `Tstat` is `Tgetattr`, and `Twstat` a `Trenameat` for a name, then a `Tsetattr`, or `Tfsync` for the null wstat. `Tremove` is `Tunlinkat` on a fid walked to the parent. A server without `Tunlinkat` or `Trenameat` (diod 1.0) gets `Tremove` and `Trename` instead. `Rlerror` becomes the error string `attr.zig` gives for the errno ("errno N" for one it doesn't know). A `Tflush` of a request that became several flushes all of them, and a reply for an unknown tag fails the connection.

Symlinks are followed during a walk with `Treadlink`, inside the mount by [symlinks-in-root](../design/symlinks-in-root.md)'s rule: an absolute target starts at the attach root, `..` stops there, and more than 40 links in one walk is "too many symbolic links". A directory read lists a link as its target, and leaves out one that resolves to nothing. A device node, FIFO, or socket is a zero-length file that fails to open.

The machine's user is sent as `n_uname` from `--user-map` (an `/etc/passwd` file read once), or else the host uid, which is 65534 when h9 runs as root and 1000 on Windows; 0 is sent only when the map says so. Any other number N is named "N" and back.

A file read sequentially is read one upstream `msize` ahead, and devmnt's 32 KiB reads are answered from that; a seek, a write, or any mutation drops it.

With `9P2000.L.Z`:

- Walks are `Twalkgetattr`, a read-only open `Tlopenatread`, which brings up to an `msize` of the file, directory reads `Treaddirattr`, and creates `Tlcreateattr`. The attributes a reply brings answer only the fid's next request, unless a mutation came since.
- Every mutation carries an envelope with an op_id from a random seed and a count.
- A dialed conversation reconnects. When the connection drops, or the server answers `ENOTLEADER`, the kproc dials the addresses again, a second apart and round the list, for up to 120 seconds, under the first dial's plan, in a namespace of its own. The translator then negotiates again, rebinds every live server fid with `Trebind` by its inode and attach root, replays each open without `O_TRUNC`, `O_CREAT`, or `O_EXCL`, and resends every unanswered request in order, mutations with the retry flag, so the server applies each once. Read-ahead and held attributes are dropped. devmnt sees slow replies; after 120 seconds outstanding requests fail as on any hangup.

A connection given by fd (`fd N`), such as a WebSocket root's or a unix root whose path has a comma, can't be redialed, so it hangs up as before.

## Serving

`--serve` makes a machine a 9P server while its program runs ([serve](../design/serve.md)). `src/serve.zig` opens every listener before the program starts, so a failure is exit 125 with nothing run, and `Machine.serving()` and the guest's `$serve` (an rc list) give the bound addresses, port 0 resolved. The listeners close when the program exits, which hangs up every connection.

### Listeners

Unix and TCP listeners are host sockets with an accept thread each.

A unix listener first takes an exclusive `flock` on `PATH.lock` (mode 0600) for the whole run, so two runs can't both decide a socket is stale; then an existing socket that refuses a connection is removed, one that answers is an address in use, and a path that isn't a socket is left alone (`not a socket`).

The socket is made mode 0600, and the socket and lock file are removed at the end of the run.

A TCP listener sets `SO_REUSEADDR`, so a port is free again as soon as the run ends.

A `ws://` listener reads the HTTP request on its accept thread and answers it with `ws.zig`'s server side: 404 for another path, 405 for another method, 426 for a request that isn't a version 13 upgrade, 403 for an `Origin` `--serve-origin` doesn't allow, 401 without the token (compared as SHA-256 digests in constant time), and 400 for subprotocols offered without `9p`; otherwise 101, selecting `9p` when it was offered.

A machine serves at most 32 connections at once; past that a connection is closed on accept, or answered 503 on a WebSocket listener, and `--trace` logs each accept and refusal.

### Streams

An accepted connection enters the kernel through devhstream as a host-made stream (`hstream.openAccepted`): raw for unix and TCP, whose bytes are queued as they arrive and written back unframed, or a server-side WebSocket, whose frames are sent unmasked and whose text messages close it with 1003.

A server stream answers pings, pings after 30 s idle and fails a connection silent for another 30 s, and drops a client whose handshake hasn't finished within 60 s. The first message passes a dialect slot (`hstream.dialect`), which takes a `Tversion` and refuses anything else. The stream then goes to a `#ℓ` conversation's server side (`serve N`), whose `data` the server Proc's exportfs serves.

### 9P2000.L clients

A `#ℓ` conversation's server side (`src/dotl/server.zig`) goes by the client's first `Tversion`: `9P2000.L` translates, `9P2000.L.Z` is answered with `9P2000.L` (version(5) lets a server pick), and anything else passes through for exportfs to answer, so a 9front or h9 client mounts as before ([dotl](../design/dotl.md)). The `serve` heading of `--print` says its listeners speak both.

Translating, it allocates exportfs's fids and tags, since one .L request can take several. `Tgetattr` is a `Tstat`, built into a Linux `stat` with numbers from the user map, and `Tsetattr` a `Twstat`. `Treaddir` reads the whole directory into a listing on the fid and hands out entry indexes as offsets; a `Treaddir` at offset 0, or any mutation through the connection, drops the listing. `Tlopen` is `Topen` and `Tlcreate` a `Tcreate`. `Tmkdir` is a walk, a create, and a clunk. `Tunlinkat` walks and removes. `Trenameat` within a directory is a `Twstat` of the name, replacing a name that's taken, and across directories is `EXDEV`. `Tfsync` is the null `Twstat`, and `Tstatfs` reports fixed sizes. `Tsymlink`, `Tmknod`, `Tlink`, and xattrs are `EOPNOTSUPP`. `Tlock` and `Tgetlock` use an advisory byte-range lock table shared by every connection the process serves, held by a connection and a client pid on a qid. exportfs's errors become errno through `attr.zig`, and `exportfs -R`'s "read only" is `EROFS`.

### The server Proc

After the plan's namespace is built and before the program runs, the first Proc forks the server Proc with `RFNAMEG|RFFDG|RFENVG|RFNOTEG|RFNOWAIT`: its own copy of the plan's namespace, so binds the program makes later aren't served, and its own note group, so an interrupt from the console doesn't reach exportfs. Without `--serve-net` it unmounts `/net`.

It takes each ready connection from `serve.Server.next`, opens its stream as an fd, puts it through a `#ℓ` conversation's server side, and forks a Proc that dups the conversation's `data` to 0 and 1 and execs `exportfs -r ROOT` (`-R` under `--write=none`): the root's `/bin/exportfs` if it has one, else the built-in root's `#Hroot/$cputype/bin/exportfs`.

When exportfs exits, the stream closes and the connection's slot is freed.

With no program (`argv` empty), the first Proc sleeps until a note or the end of the run instead of exec'ing anything, and the CLI exits 0 when a note ends it.

### Process counts

The server Proc and its descendants are counted against `--pids` separately from the program's processes, each against the full value, so neither can use up the other's (`pids=32 (+32 serving)` in the plan). Each connection's exportfs and its children are also capped at 8 live processes, so past 8 blocking requests the next fails with exportfs's `Out of processes` while other connections carry on. Memory isn't split: exportfs counts under `--memory` with the program.

### The plan

`--print` lists the listeners under `serve:`, each with the exportfs command it runs and, for WebSocket listeners, `(token, origins: …)` without the token's value; the heading's comment says which exportfs runs. Caveats name each listener without authentication (unix, TCP, and WebSocket without a token) and, under `--serve-net`, that clients can dial out from the host's address. A serve-only run prints `program:  none (serve only)`.
