---
slug: mount-index
title: Metadata indexes for 9P roots and mounts
status: draft
created: 2026-11-09
authors: [progrium]
depends: [13, 21, 32]
areas: [cli, kern]
---

# Proposal: Metadata indexes for 9P roots and mounts

## Abstract

A [9P root](0013-9p-roots.md), or a 9P server a namespace file mounts, can come with an index: one file listing every name in the tree with its qid, mode, length, mtime, and owner, and none of the contents. h9 reads it once, caches it on the host across runs, and answers walks, stats, and directory reads from it, so only opens and reads of files go to the server. Each directory is checked against the server once per run, in one pipelined batch when the tree is mounted, and each file is checked when it's opened. Anything that doesn't match is demoted to plain 9P for the rest of the run, so a stale index costs round trips, never wrong answers.

The index is either a file at the top of the tree, `/.h9index`, or, for the root, one given with `--root-index FILE|URL`, so it can be layered over a server that can't be written to. A server that keeps its `/.h9index` current as the tree changes makes this work for mutable trees too, such as home directories: they're fast from the first `ls`, and only what changed since the index was written is demoted. A new guest command, `mkindex`, builds it by walking a mounted tree, so the qids in it are the server's own. The index is text on the wire and a compiled binary form in the cache.

## Background

### h9 today

- **[9p-roots](0013-9p-roots.md)** mounts a 9P server at `/` through devmnt: a `tcp!` dial string, a unix socket, or, with [websocket-9p](0021-websocket-9p.md), a `ws://` or `wss://` URL, which [schemeless-roots](0076-schemeless-roots.md) lets you write without the scheme.
- **devmnt sends one request per operation and waits for its reply.** Its caller is a guest process, so latency per operation, not bandwidth, is what a remote root costs. devmnt has no cache of its own in drawterm's tree.
- **Startup is mostly metadata.** Before a program does useful work, rc searches `$path`, a Linux program's loader probes library directories, and the program stats and opens its configuration. Each name looked up is a `Twalk`, often followed by a `Tstat`, and a missing name is a full round trip that returns nothing.
- **[overlay](0011-overlay.md)** puts `#O` over the root by default, so the guest's writes to the root land in memory and never reach the server. A root mounted that way is read-only as far as the server is concerned.
- **[dotl](0022-dotl.md)** (draft) puts a translator between devmnt and every 9P connection, which answers some requests from compound .L.Z replies. It caches attributes only until the next mutation, because ZeroFS's trees are mutable, and only within one connection.

### The opportunity

A root is a large tree that changes rarely and is read by many runs. Its metadata (names, qids, modes, and lengths) is small next to its contents: a few hundred bytes a name. If h9 had the whole tree's metadata before the program started, nearly every startup round trip but the opens and reads would disappear, and a negative lookup would cost nothing.

The same pattern is proven elsewhere: CernVM-FS ships per-tree catalogs and fetches file contents on demand, Nydus separates an image's "bootstrap" metadata from its data, and eStargz puts a table of contents at the end of each layer. Each of those needs its own server or image format. This proposal keeps plain 9P and any server h9 already mounts.

## Proposal

### The index file

A text file, UTF-8, one entry per line, sorted by path in byte order:

```
h9index 1
/ 0000000000000001 7 d 020000000775 0 1730851200 sys sys
/bin 0000000000000002 3 d 020000000775 0 1730851200 sys sys
/bin/ls 0000000000002a1f 3 - 0775 81920 1730851200 glenda sys
```

The fields are separated by single spaces: path, qid.path in hex, qid.vers in decimal, qid.type (`d` for a directory, `a` for append-only, `l` for exclusive, `-` otherwise), mode in octal with Plan 9's `DM` bits, length, mtime in seconds, uid, and gid. They're `stat(5)`'s, as devmnt sees them: a .L server's attributes reach the index already converted by whatever translator the mount goes through. The first line is the format and its version. A line h9 can't parse fails the whole index, which is then not used (see Failures).

A path is everything from the first field to the first space, so a name with a space, a newline, or a byte that isn't UTF-8 can't be listed. `mkindex` leaves such an entry out and marks its directory `unindexed` with a line `!unindexed /path/to/dir`, and h9 never answers for that directory from the index. That keeps negative lookups correct: a name missing from an indexed directory is a name the server doesn't have.

### Building one: `mkindex`

`mkindex [-o FILE] [DIR]` is an rc script in [guest-tools](0032-guest-tools.md)' `/bin`, beside `wsmount`. It walks `DIR` (default `/`) with `walk(1)`'s `-e` format and writes the index to standard output or FILE:

```
h9 --root wss://roots.example/alpine mkindex / >alpine.h9index
h9 --rc 'wsmount wss://fs.example/data /n/d && mkindex /n/d' >data.h9index
```

It stats the tree through devmnt, so every qid in the index is what the server reports, which matters because h9 later pairs stats from the index with opens from the server. It works on any tree h9 can mount, including one whose host files you can't see. It skips `/.h9index` itself, and, under the root, the paths the namespace builder binds over it (`/dev`, `/proc`, `/mnt/term`, `/tmp`, and the rest of [policy](../src/policy.zig)'s binds), by walking the mount's own channel through `/srv/root` rather than the guest's `/`.

`walk` isn't in [builtin-root](0087-builtin-root.md)'s command set, so this proposal adds it there, so `mkindex` works over a root that has no 9front commands, such as a Linux image, with `--builtin=before`.

### Using one

| Flag | Meaning |
| --- | --- |
| `--root-index FILE\|URL` | Use this index for the 9P root instead of its `/.h9index`. A URL is `https://` or `http://` and is fetched with the root's `--root-ca` and proxy settings. |
| `--index auto\|none` | `auto`, the default, uses an index wherever one is found: `--root-index` for the root, and `/.h9index` on each 9P server h9 mounts. `none` uses none. |
| `--index-cache DIR` | Where compiled indexes are kept. Default: `$XDG_CACHE_HOME/h9/index`, `~/Library/Caches/h9/index` on macOS, `%LOCALAPPDATA%\h9\index` on Windows. |

Indexes apply to the 9P connections h9 makes on the host: the root (`tcp!`, `unix!`, and WebSocket), and the 9P servers a namespace file mounts by dial string or URL, such as `mount -c wss://home.example/u/jeff /usr/jeff`. A namespace-file mount uses the server's `/.h9index`; there's no way yet to give it another (see Open issues). `--root-index` with a host-directory root is a usage error, since `#U` is already local. Mounts the guest makes itself, with `mount` or `wsmount`, don't use an index.

`Machine.Options` gains `index: enum { auto, none }`, `root_index: ?RootIndex`, a union of `path` and `url`, and `index_cache: ?[]const u8`.

### Fetching and caching

When the root, or a namespace file's 9P server, is mounted:

1. **Find the index.** For the root with `--root-index FILE` or `URL`, read it. Otherwise walk to `/.h9index` on the server and stat it; if it's missing, the mount is ordinary 9P and nothing below happens.
2. **Use the cache.** A server index is cached under the server's address and attach spec, with the index file's qid and mtime as its version. If they match the cached entry, h9 uses the compiled form without reading the file. Otherwise it reads the file, compiles it, and replaces the entry. A file or URL index is cached by the SHA-256 of its text; a URL is fetched each run with `If-None-Match` on the last `ETag`, so an unchanged one costs a round trip and no transfer.
3. **Validate the directories** (below), then start the program.

The compiled form is a single file built for mapping into memory: a header, an array of fixed-size entries (qid, mode, length, mtime, user indexes, a name's offset and length, the parent, and the first child and child count, with each directory's children contiguous and sorted by name), a user table, a string table, and a SHA-256 trailer over the rest. A walk is a binary search in a directory's children; a stat builds a `Dir` from an entry; a directory read goes through the children in order. Its layout is internal to h9, versioned in its header, and rebuilt from the text whenever the version differs.

The cache directory is created mode 0700, and its files 0600. Entries not used for 30 days are removed when h9 next writes the cache.

### Serving from the index

The index sits between devmnt and the server's connection, as a new kernel device, `#ι`, which devmnt mounts in place of the connection's channel. Like [devhstream](../src/kern/devhstream.c), its logic is Zig (`src/rootindex.zig`), a state machine over 9P messages with no I/O of its own, and the device moves bytes between it, devmnt, and the connection. When [dotl](0022-dotl.md)'s translator exists, the index layer sits above it and still speaks only 9P2000.

It keeps every fid devmnt uses, and each is either **real** (the server has it) or **virtual** (only the index knows it, by its path):

| devmnt sends | With the index |
| --- | --- |
| `Tversion`, `Tauth`, `Tattach` | Forwarded. The attach fid is real. |
| `Twalk` | If every step is a name looked up in an indexed, validated directory, answered locally, and `newfid` is virtual. A missing name gives the same `Rwalk` or `Rerror` the server would. Otherwise it's forwarded from the last real fid on the path, after making the starting fid real if it's virtual. |
| `Tstat` | A virtual fid's, or a real fid's whose entry is still valid, answered from the entry. |
| `Topen` of a directory, then `Tread` | Answered locally from the children, as `Dir` records, if the directory is validated. |
| `Topen` of a file | The fid is made real, by one `Twalk` from the attach fid along its path, and the open is forwarded. The reply's qid is checked against the entry (below). |
| `Tread`, `Twrite` on a real fid | Forwarded. |
| `Tcreate`, `Tremove`, `Twstat` | The fid is made real and the request forwarded. On success, the directory it changed is demoted. |
| `Tclunk` | A virtual fid's is answered locally; a real one's is forwarded. |
| `Tflush` | Forwarded if the request it flushes went to the server, answered locally otherwise. |

Making a virtual fid real is one `Twalk`, and devmnt would have sent that walk itself, so an open never costs more round trips than it does without an index. The index never holds or serves file contents.

### Staying correct

The index is a hint, checked against the server:

- **Directories are validated once per run, when the server is mounted.** h9 walks a fid to every indexed directory and stats it, with up to 64 requests outstanding at once, then clunks them. That's about two round trips for the whole tree plus the transfer. A directory whose qid.path, qid.vers, or mtime differs from its entry is **demoted**. Adding, removing, or renaming an entry changes a directory's qid.vers on 9front's file servers and its mtime on a Linux one, so a directory that validates has the listing the index says, and the index can answer "file does not exist" for it.
- **Files are checked when they're opened,** from the open's own reply, which carries the qid. A file whose qid.path or qid.vers differs is demoted, and devmnt's next stat of it goes to the server.
- **Demoted** means served by plain 9P for the rest of the run: walks into or through a demoted directory are forwarded, and stats of a demoted entry go to the server. Nothing else in the index is affected.
- **Mutations** forwarded through the mount demote what they touch. Under `#O`, the default for roots, the guest's writes don't reach the server at all. A writable mount, such as a home directory, demotes each directory as the guest changes it, and the rest of the index keeps answering.
- **If more than a quarter of the directories are demoted,** h9 prints a note under `-v` that the index looks stale, and, for a server index, says to rebuild it with `mkindex`. It doesn't rebuild it itself.

### Mutable trees

An index only stays useful for a tree that changes if the server keeps it current. That's the server's job, not h9's: a server that indexes a mutable tree, such as a gateway in front of ZeroFS serving home directories, rewrites `/.h9index` as the tree changes, by writing a new file and renaming it over the old one. It can rewrite on every change, or batch changes and rewrite every few seconds; either way, the index file's qid and mtime change, so the next mount fetches the new one. A home directory's index is small, a few hundred bytes a name, so refetching it whole is cheap.

Whatever changed between the index's last rewrite and the mount is caught by validation and demoted, and whatever this run changes is demoted as it happens. So the index never needs to be exactly current to be correct: a server that rewrites it often keeps more of it useful, and one that never does degrades to plain 9P one directory at a time. Two clients writing the same tree see each other's changes as they would without an index, since every open and read goes to the server and every stale directory is demoted at the next mount.

What a run doesn't see is a change another client makes during the run to a directory this run already validated: a new name stays invisible to walks until the next mount, and a removed one still shows in listings, though opening it fails. That's the same as any client-side cache of a shared tree. A run that needs to see such changes immediately uses `--index none` (see Open issues for a per-mount switch).

What's not checked: a file whose contents change in place without a change to its directory shows its old length and mtime to `stat` until it's opened. Its contents are always the server's, since reads always go there. This is the same window as an NFS client's attribute cache, and it only arises when a tree is edited after its index was built and not reindexed.

### What the user sees

- `--print` shows the index in the root's line: `root wss://roots.example/alpine index=/.h9index 1482 entries 212 dirs`, or `index=none`.
- `-v` reports the validation: how many directories were checked and demoted, and how long it took.
- `--check` fetches and validates the index, and reports the same.

### Failures

An index never makes a root fail to mount that would have mounted without one:

- A `--root-index FILE` that can't be read, or a URL that can't be fetched, is exit 125, as for any root that can't be reached, since you asked for it by name.
- An index that doesn't parse, whose format version h9 doesn't know, or that's larger than 256 MB, is ignored with a note under `-v`, and the mount is ordinary 9P. So is a cache file whose trailer doesn't match.
- A cache directory that can't be written means the index is compiled in memory for this run only.

## Rationale

**Why an index, not a bigger cache in the translator.** A cache filled as the program runs saves the second lookup of a name, not the first, and startup is mostly first lookups. Only something that knows the tree beforehand can answer a first lookup, or a negative one, without asking. An index also tells h9 which directories exist, which is what lets it validate all of them in one pipelined batch even though devmnt can't pipeline.

**Why validate at all.** Without validation the index would be a promise about a server the client doesn't control. With it, the worst a stale or wrong index does is cost the round trips it would have saved. A future content-addressed root, whose tree is pinned by hash, could skip validation safely; see Open issues.

**Why validate directories by stat, not by reading them.** Reading every directory validates every file too, but transfers the tree's metadata on every run, which is what the cache exists to avoid. A directory's stat changes when its listing does, which is what negative lookups depend on, and file changes are caught at open, which is what reads depend on.

**Why text on the wire.** `mkindex` is an rc script, which can't sensibly write a binary format, and a text index can be diffed, read, and checked by hand. The binary form exists only in the cache, where its layout can change with h9 without breaking any published index.

**Why build it in the guest.** A host tool would read host files, whose inode numbers aren't the qids a server reports, and couldn't index a remote tree at all. `mkindex` walks the tree through the same devmnt the index will later stand in for.

**Why `--root-index` as well as `/.h9index`.** Many servers can't be written by the person running h9: someone else's export, a read-only ZeroFS replica or checkpoint, or a server that converts images into trees. A separate index can be published anywhere, next to a lockfile or on a CDN, and laid over the same root. It must be a flag, not a namespace-file `bind`, because the index layer is set up when the root is mounted, before the namespace file is replayed.

**Why mutable trees rely on the server.** h9 can't keep an index current, because it doesn't see other clients' changes, and building one itself means reading the whole tree, which is the cost the index exists to avoid. The server sees every change, so it's the one place an index can be kept current cheaply. Validation and demotion mean h9 never has to trust that it did. For the parts that are demoted, fewer round trips per operation is dotl's .L.Z work, which complements this.

**Rejected: updating the index in place from the guest's own writes.** A create's reply has the new file's qid but not its parent directory's new version, so the client can't revalidate the directory without a stat, and an index edited by every client would diverge from the server's. Demoting is simpler, and the server's next rewrite restores the directory.

**Why not a content-addressed store now.** Putting each file's chunk hashes in the index would let h9 serve reads from a local block cache shared across runs and roots, and fetch blocks over plain HTTP. That changes how contents are fetched, needs a server that stores trees that way, and isn't needed for the startup win, which is metadata. This proposal's format leaves room for it: a later version can add fields to each line.

**Rejected: a well-known file per directory.** Spreading the index over the tree makes every directory cost a read on first use, which is the round trip this proposal removes.

**Rejected: discovering the index over HTTP beside the WebSocket.** It only works for WebSocket roots, and needs the server to answer something other than 9P. `/.h9index` works over every transport.

## Compatibility

- **New flags,** `--root-index`, `--index`, and `--index-cache`, and `Machine.Options.index`, `root_index`, and `index_cache`. No existing flag changes.
- **A root or namespace-file mount whose server has `/.h9index` behaves differently by default:** faster, and, for a tree edited without reindexing, with stale lengths and mtimes to `stat` until a file is opened, and with other clients' changes during the run not seen by walks (see Mutable trees). `--index none` restores the old behaviour.
- **Exit codes:** only an unreadable `--root-index` is new, and it's 125, as for an unreachable root.
- **The root tree:** `/.h9index` is an ordinary file in it, visible to the guest.
- **The built-in root** gains `walk`, about 20 KB per architecture.
- **`third_party/`:** none. devmnt is unchanged; it mounts `#ι`'s channel as it mounts any other.

## Security

The guest can reach nothing new. The index layer only answers requests devmnt would have sent to the server, and every open, read, and write still goes to the server under the same attach, user, and auth.

A malicious index, from a server or a URL, can show the guest names that don't exist (opening them fails) or hide names that do, the same as a malicious server. It can't make a read return anything but the server's data. The parser is bounded: the 256 MB limit, entries checked against the tree's shape (every path's parent is an earlier directory), and no field trusted as an offset until checked.

The cache is per user, mode 0700, and each compiled file is checked against its trailer before use, so a corrupted file is rebuilt rather than trusted. The cache holds the names, owners, and sizes of every file in each indexed tree, which can be sensitive for a private tree. `--index-cache` can point it somewhere else, and deleting the directory is always safe.

A URL index is fetched by h9 on the host, like a WebSocket root, under the root's TLS and proxy settings, and not under the guest's `--net` policy.

## Done when

Integration cases tagged `[mount-index]`. The server is the second h9 serving the test root with exportfs, as in 9p-roots' cases, behind a relay that counts T-messages:

- `test "mkindex lists every name in the test root with the server's qids [mount-index]"`
- `test "mkindex marks a directory with a name containing a newline unindexed [mount-index]"`
- `test "a root with /.h9index runs /bin/ls [mount-index]"`
- `test "an indexed root sends no Twalk for a missing name in a validated directory [mount-index]"`
- `test "an indexed root sends fewer T-messages than an unindexed one for rc -c echo [mount-index]"`
- `test "--root-index FILE is used over a root without /.h9index [mount-index]"`
- `test "a second run uses the cache and doesn't read /.h9index [mount-index]"`
- `test "a file added after indexing is found, by demoting its directory [mount-index]"`
- `test "a file removed after indexing is not found [mount-index]"`
- `test "a file changed in place reads the server's contents [mount-index]"`
- `test "a malformed index is ignored and the root still mounts [mount-index]"`
- `test "an unreadable --root-index exits 125 [mount-index]"`
- `test "--index none ignores /.h9index [mount-index]"`
- `test "a namespace-file mount of a server with /.h9index uses it [mount-index]"`
- `test "a file created through a writable indexed mount is found by the next walk [mount-index]"`
- `test "a rewritten /.h9index is fetched on the next mount [mount-index]"`
- `test "--root-index with a host-directory root is a usage error [mount-index]"`
- `test "--print shows the index source and entry count [mount-index]"`

Unit tests for `src/rootindex.zig`, with recorded conversations: walks, stats, and directory reads answered locally; virtual fids made real; flushes; demotion on a mismatched open; and the parser's limits.

Demo: with the test root served over `ws://` behind a relay that adds 50 ms each way, `time h9 --root ws://localhost:8080/9p rc -c 'ls /bin | wc -l'` before and after `mkindex / >/tmp/x.h9index` and `--root-index /tmp/x.h9index`, with the T-message counts from `-v`.

## Implementation

1. `walk` in the built-in root's command set.
2. `mkindex` in `src/guest/bin`, with its cases.
3. The text parser and the compiled form, in `src/rootindex.zig`, with unit tests.
4. The index layer's state machine, with recorded-conversation tests.
5. `#ι` in `src/kern/devhidx.c`, and the root mount in `src/main.zig` and `src/machine.zig` putting it between devmnt and the connection when an index is found.
6. Validation at mount, and demotion.
7. The cache, `--root-index`, `--index`, `--index-cache`, `--print`, `-v`, and `--check`.
8. Namespace-file mounts, through the same layer.
9. URL indexes, through `src/ws.zig`'s HTTP client.
10. MANUAL and DESIGN.md.

## Open issues

- **Lazy validation.** A 9front root has thousands of directories. Validating them all at mount is two round trips but a lot of small messages; validating each on first use costs a round trip per directory the program touches. Which default is better needs measuring on a real remote root, and maybe a threshold.
- **Per-mount control.** A namespace-file mount can't name an index other than its server's, or turn indexing off for itself alone, because `mount`'s flags are 9front's. A spec suffix or an h9-only flag would do it. The guest's own `mount` and `wsmount` could use the layer too, once roots prove it.
- **Incremental updates.** A server rewriting a large mutable tree's index refetches it whole on every client. A later version could add a change log beside the index, so a client fetches only the entries since its cached version.
- **Writing the index for ZeroFS.** ZeroFS doesn't write `/.h9index` itself. A gateway in front of it, or a periodic `mkindex`, would; which one is a deployment choice, not part of h9.
- **The browser host** has no cache directory. The embedder could pass the compiled index in, or h9-web could keep it in the Cache API.
- **Skipping validation.** A root pinned by content hash can't change, so its index needs no checking, but 9P has no way to say a tree is pinned. That belongs with a content-addressed root kind, which this format is meant to grow into.
- **The device's letter.** `#ι` is a placeholder.
