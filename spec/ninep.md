# Roots, 9P, and serving

This describes, as built, what a root can be, the 9P dialects h9 speaks to file servers, and how a machine serves its own namespace over 9P. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Root filesystem](#root-filesystem)
- [Credential helpers](#credential-helpers)
- [9P dialects](#9p-dialects)
- [Metadata indexes](#metadata-indexes)
- [Serving](#serving)
  - [Listeners](#listeners)
  - [Streams](#streams)
  - [9P2000.L clients](#9p2000l-clients)
  - [The server Proc](#the-server-proc)
  - [Process counts](#process-counts)
  - [The plan](#the-plan)

## Root filesystem

The root is either a directory holding an extracted 9front root, served through `#U` (devfs-posix or devfs-win32), which is the fastest path, with no 9P round trips; or a 9P server ([ninep-roots](../design/epoch-0/ninep-roots.md)), named by `--root tcp!host!port` (`tcp!host` means port 564), `unix!path`, the path of a unix socket, or a `ws://` or `wss://` URL.

A value that isn't an existing path and is shaped like `host[:port][/path]` (a dotted host, a bracketed address, a port, or `localhost`, and nothing starting with `.`, `/`, `~`, or `-` or containing `\`, `!`, `@`, or whitespace) is a URL without its scheme ([schemeless-roots](../design/epoch-0/schemeless-roots.md)): `ws://` for `localhost`, `127.0.0.0/8`, and `[::1]`, and `wss://` otherwise, as `cli.schemelessRoot` reads it.

The path is tried first, so a directory named like a host stays a directory, and when such a root can't be reached h9 says it read the value as a URL.

h9 connects to a 9P root before the program runs:

- A TCP root is dialed through devip by device path (`#I/cs` and `#I/tcp/clone`), outside the network policy, since h9 makes the connection and the guest can't dial anything through it.
- A unix socket root is connected on the host and wrapped as a channel with devlfd's `lfdchan` (`src/kern/rootdial.c`), on POSIX hosts only.
- A `ws://` or `wss://` root is connected by `src/hstream.zig` (TCP, TLS, the HTTP proxy if one applies, and the handshake), and its stream's channel comes from devhstream.

The connection is posted on the machine's `/srv` board as `root`, which holds it for the machine's life, and `#s/root` is mounted at `/` with no auth fd and `--root-spec` as the attach name. devmnt sends the calling process's user as the attach uname, so the first Proc takes on `--root-user` for the mount when one is given. Everything else is bound over the mount as over a host tree.

Each connection goes through a `#ℓ` conversation before it's posted (see [9P dialects](#9p-dialects)), so the server can speak 9P2000 or 9P2000.L; a TCP root, and a unix one whose path has no comma, is dialed by the conversation itself, so it can be dialed again. A refused connection, a failed `Tversion` or `Tattach` (a server that wants authentication, or one that speaks an unknown dialect) is exit 125 with the server's error; a hangup later fails file operations as devmnt does, unless a 9P2000.L.Z server's connection is resumed. Disk images aren't supported ([image-roots](../design/epoch-0/image-roots.md) was declined).

## Credential helpers

Before each WebSocket handshake h9 makes, for the root, a namespace file's `mount`, or a 9P2000.L.Z reconnect of either, it runs the credential helper whose `--cred PATTERN=COMMAND` matches the URL, and sends the headers it prints with the handshake ([credential-helpers](../design/credential-helpers.md), `src/cred.zig`). Guest `/net/ws` conversations never run one.

- **Patterns** are scheme-less URL prefixes, matched on a host and path boundary, such as `wanix.io/data`, with a leading `*.` matching any subdomain of a domain that follows it. The longest matching pattern wins, and of equally long ones the first given. `--cred` entries come before `$H9CRED`'s, which is a list of the same separated by `;`; a bad entry in either is exit 2.
- **The exchange:** the command is split on spaces and tabs and run as `argv… get URL` with the URL unelided, stdin empty, stdout piped, and stderr passed through. It has 30 seconds. Its output is `Name: value` lines up to a blank line or EOF, checked as `--root-header`'s are. A failure is exit 125 for the root, or the mount's error, with `credential helper NAME:` and the first line of its stderr or its exit status.
- **A refusal:** when the server answers 401 or 403, the helper is run once more with the response's status line and headers on stdin, and its new headers are tried. A second refusal ends with `(after credential helper retry)`.
- **Merging:** `--root-header` wins over a helper's header of the same name, compared without case.
- **Secrets:** the output is zeroed once the handshake is sent. A match on a `ws://` URL warns that the headers cross the network in plaintext.

A handshake's `101` may carry `9P-Uid: N` and `9P-User: NAME`, the uid the server serves files as for this client and its name. With neither `--user-map` nor `--root-user`, h9 writes them to the connection's `#ℓ` `ctl` as `user N NAME`, so the connection's user map maps N to NAME both ways and the attach sends NAME and N. A name longer than 27 bytes, or with a space, `:`, `/`, or a control character, is ignored, the former with a warning.

## 9P dialects

Every 9P connection h9 mounts, from a TCP, unix socket, or WebSocket root, a namespace file's `mount`, or the guest's `dotlfs`, goes through a `#ℓ` conversation's client side before devmnt sees it ([dotl](../design/epoch-0/dotl.md)). The translator answers devmnt's `Tversion` with `9P2000` itself and sends its own, with tag `NOTAG`, offering `9P2000.L.Z` at an `msize` of up to 1 MiB:

- `9P2000.L.Z` or `9P2000.L` translates, `.L.Z` with ZeroFS's extension.
- `9P2000` passes bytes through both ways unchanged, so a 9front server costs a copy.
- `unknown`, or an `Rlerror` (diod's answer), to the `.L.Z` offer gets an offer of `9P2000.L`; anything else fails the mount with "server speaks unknown 9P version X".

Translating, the client side allocates the server's fids and tags, since one devmnt request can become several, and keeps each fid's path from its attach root. `Topen` is `Tlopen`, with `ORCLOSE` kept in the translator and done at clunk. `Tcreate` is `Tlcreate`, or `Tmkdir` then a walk and `Tlopen` for a directory, with the mode create(5)'s rule gives against the directory's (a .L server applies none). A create of an existing name without `DMEXCL` opens it truncated. Directory reads are `Treaddir` and a `Tgetattr` per entry, packed into `Dir`s. `Tstat` is `Tgetattr`, and `Twstat` a `Trenameat` for a name, then a `Tsetattr`, or `Tfsync` for the null wstat. `Tremove` is `Tunlinkat` on a fid walked to the parent. A server without `Tunlinkat` or `Trenameat` (diod 1.0) gets `Tremove` and `Trename` instead. `Rlerror` becomes the error string `attr.zig` gives for the errno ("errno N" for one it doesn't know). A `Tflush` of a request that became several flushes all of them, and a reply for an unknown tag fails the connection.

Symlinks are followed during a walk with `Treadlink`, inside the mount by [symlinks-in-root](../design/epoch-0/symlinks-in-root.md)'s rule: an absolute target starts at the attach root, `..` stops there, and more than 40 links in one walk is "too many symbolic links". A directory read lists a link as its target, and leaves out one that resolves to nothing. A device node, FIFO, or socket is a zero-length file that fails to open.

The machine's user is sent as `n_uname` from `--user-map` (an `/etc/passwd` file read once), or else the host uid, which is 65534 when h9 runs as root and 1000 on Windows; 0 is sent only when the map says so. Any other number N is named "N" and back.

A file read sequentially is read one upstream `msize` ahead, and devmnt's 32 KiB reads are answered from that; a seek, a write, or any mutation drops it.

With `9P2000.L.Z`:

- Walks are `Twalkgetattr`, a read-only open `Tlopenatread`, which brings up to an `msize` of the file, directory reads `Treaddirattr`, and creates `Tlcreateattr`. The attributes a reply brings answer only the fid's next request, unless a mutation came since.
- Every mutation carries an envelope with an op_id from a random seed and a count.
- A dialed conversation reconnects. When the connection drops, or the server answers `ENOTLEADER`, the kproc dials the addresses again, a second apart and round the list, for up to 120 seconds, under the first dial's plan, in a namespace of its own. The translator then negotiates again, rebinds every live server fid with `Trebind` by its inode and attach root, replays each open without `O_TRUNC`, `O_CREAT`, or `O_EXCL`, and resends every unanswered request in order, mutations with the retry flag, so the server applies each once. Read-ahead and held attributes are dropped. devmnt sees slow replies; after 120 seconds outstanding requests fail as on any hangup.

A connection given by fd (`fd N`), such as a unix root whose path has a comma, can't be redialed, so it hangs up as before. A WebSocket root's or a namespace file's WebSocket mount is given by fd too, but h9 writes its URL with `redial` first, so a reconnect opens a new host stream, running the credential helper again.

## Metadata indexes

A 9P root, and a 9P server a namespace file mounts by dial string or URL, goes through a `#ι` conversation above its `#ℓ` one ([mount-index](../design/mount-index.md)), unless `--index none`. The conversation's layer (`src/rootindex/layer.zig`) is a state machine over 9P2000 bytes, with no I/O of its own, between devmnt and the server.

The index is the server's `.fs/index`, in [dotfs](https://github.com/progrium/dotfs/blob/main/docs/9p-dotfs.md)'s `fsindex 1` format, or for the root a `--root-index` file or `https://` or `http://` URL in the same format. Its text is a header `fsindex 1 seq N`, then a line per name sorted by the unescaped path's bytes, `path type mode length mtime version hash flags [target] [key=value...]`, with paths and values percent-escaped. h9 reads `9p.qid=PATH.VERS` (hex qid.path, decimal qid.vers), `9p.mode` (the whole 9P mode, in octal, where it has `DM` bits beyond `DMDIR`), `9p.uid`, `9p.gid`, and `9p.incomplete=1`, a directory whose listing isn't whole; a symlink entry makes its parent incomplete, and the `i` flag makes the directory itself incomplete. Without `9p.qid`, an entry's qid.path is the first 8 bytes of its path's SHA-256, and its qid.vers the low 32 bits of its version; without owners, the attach's user. `.fs` itself is never listed. `src/rootindex.zig` compiles the text to a form checked by a SHA-256 trailer: a header with the seq, fixed 72-byte entries in breadth-first order with each directory's children contiguous and sorted, a user table, and strings. A line that doesn't parse, lines out of order, an encoding (`zstd`) or a version it doesn't know, or text over 256 MB means no index, with a note under `-v`, and the mount is plain 9P.

The first `Tattach` is held while the layer, with fids from `0xF0000000` and tags from `0xFFFE` down to `0xF000` of its own:

1. clones the attach fid;
2. walks to `.fs/index` and stats it, and looks its version (qid.path, qid.vers, mtime, and length) up in the cache under the server's key, or reads it, up to 16 reads in flight, compiles it, and stores it; at the same time it walks to `.fs/events`, opens it read-write and writes `coalesce` (or opens it read-only if that fails), and reads its first record, `seq N`;
3. with events, follows the server: the index is used only if its seq is at least N, and no directory is validated. Each later record past the index's seq (`put`, `del`, `flags`, and both paths of `mv`) demotes what it names, and a `reset`, or the stream ending, stops the index's use for the rest of the run, with a note under `-v`;
4. without events, stats the root, and demotes it if its qid.path, qid.vers, or mtime differs (mtime alone for an entry without `9p.qid`). Creating `.fs` changes the root's own mtime, so a root whose stat alone differs is checked by reading its listing instead: if the names and qids match the index, its entries stand and only its stat comes from the server.

Later attaches pass through, so `mount /srv/root` sees the server itself. A devmnt tag of `0xF000` or above fails the conversation.

Without events, any other indexed directory is validated the first time a request needs the index to answer for it: a `Twalk` into or through it, or a `Tstat` or `Topen` of it. The request waits while the layer walks a fid of its own to the directory, stats it, and clunks it, and is then handled again; a `Twalk` validates every directory on its path through the index at once, up to 64 in flight, and a directory is validated at most once per run. A directory whose qid.path, qid.vers, or mtime differs (mtime alone without `9p.qid`) is demoted. A `Tflush` of a waiting request is answered locally, and the request dropped.

Then a walk through validated (or followed), indexed directories is answered locally, except for `.fs` at the top, which is always forwarded, with a missing name answered as the server would, and its fid is virtual; any other walk is forwarded, from the attach fid as one `Twalk` when its path is 16 names or fewer. `Tstat` of a virtual fid, or a real one whose entry stands, is answered from the entry, and a validated directory's `Topen` and `Tread`s from its children. A file's `Topen` makes the fid real, by walks of up to 16 names from the attach fid's clone, and is forwarded; a reply whose qid differs from the entry, or an open for writing, demotes it. For an entry without `9p.qid`, the server's qid in `Rwalk`, `Ropen`, and `Rstat` is replaced by the entry's, so a path has one qid however it's reached. `Tcreate`, `Tremove`, `Twstat`, and a `Twrite` demote what they change. `Tflush` is forwarded, so its `Rflush` can't overtake an earlier one's, except for a request still waiting on its fid to be made real, which is answered locally and never sent. A demoted entry is served by plain 9P for the rest of the run. Over a quarter of the directories validated demoted is a note under `-v`, at the end of the run, that the index looks stale.

The cache (`src/rootindex/cache.zig`) is `--index-cache`, by default `$XDG_CACHE_HOME/h9/index` (or `~/.cache/h9/index`), `~/Library/Caches/h9/index` on macOS, and `%LOCALAPPDATA%\h9\index` on Windows, made 0700 with files 0600. A file is named for 12 bytes of its key's SHA-256 and 8 of its version's, and holds the compiled form, checked against its trailer on every read; storing a key's new version removes its others, and a write removes entries not used for 30 days. A `--root-index` text is keyed `text` and versioned by its SHA-256. A URL is fetched on the host by `hstream.fetchIndex`, through the root's `--root-ca` and proxies, with `If-None-Match` on the `ETag` kept beside it (`u-<hash>.etag`), so a `304` uses the cached form. A cache that can't be written isn't, and the index is used for that run.

`--print` adds `index=/.fs/index`, `index=none`, or `index=FILE N entries M dirs` (a URL with its query elided, and no counts) to the root's line; it reads a `--root-index` file to count it but connects to nothing. `-v` prints the notes, and at the end how many of the root's directories were validated and demoted (for a followed index, how many changes it followed and how many directories they demoted), and how many requests devmnt sent the root and how many reached the server, apart from those that found the index and validated directories (the status file's `end:` lines and its `requests` line). `--check` runs with `-v`'s notes and prints them under the root's line.

`mkindex [-o FILE] [-s SPEC] [DIR]`, in `#H/bin`, writes `fsindex 1` text with `walk -e qxsmUGp`, with seq and every version `0`, no hashes or flags, `9p.qid`, `9p.uid`, and `9p.gid` on every line, and `9p.mode` where the mode, rebuilt from its symbolic form and qid.type, has `DM` bits beyond `DMDIR`. It escapes each path a rune at a time, and sorts the lines by their unescaped paths. For `/` it walks `/srv/root`, mounted with SPEC over `/tmp` in a namespace of its own, so nothing h9 binds over the root is listed. It leaves out `.fs` and everything in it. It leaves out a name with a control character, U+FFFD (a byte that isn't UTF-8), or a rune past U+FFFF, and the record before a line that is neither a record nor the rest of a warning (the rest of a name with a newline), and marks the directory `9p.incomplete=1`; a directory walk can't open or read is marked too, as is one whose listing devmnt refuses for a name with a newline in it.

## Serving

`--serve` makes a machine a 9P server while its program runs ([serve](../design/epoch-0/serve.md)). `src/serve.zig` opens every listener before the program starts, so a failure is exit 125 with nothing run, and `Machine.serving()` and the guest's `$serve` (an rc list) give the bound addresses, port 0 resolved. The listeners close when the program exits, which hangs up every connection.

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

A `#ℓ` conversation's server side (`src/dotl/server.zig`) goes by the client's first `Tversion`: `9P2000.L` translates, `9P2000.L.Z` is answered with `9P2000.L` (version(5) lets a server pick), and anything else passes through for exportfs to answer, so a 9front or h9 client mounts as before ([dotl](../design/epoch-0/dotl.md)). The `serve` heading of `--print` says its listeners speak both.

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
