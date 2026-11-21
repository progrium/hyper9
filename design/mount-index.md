---
slug: mount-index
title: Metadata indexes for 9P roots and mounts
status: draft
created: 2026-11-09
authors: [progrium]
depends: [ninep-roots, websocket-9p, guest-tools]
areas: [cli, kern]
branch: [mount-index]
---

# Proposal: Metadata indexes for 9P roots and mounts

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

A [9P root](epoch-0/ninep-roots.md), or a 9P server a namespace file mounts, can come with an index: one file listing every name in the tree with its type, mode, length, and mtime, and none of the contents. h9 reads it once, caches it on the host across runs, and answers walks, stats, and directory reads from it, so only opens and reads of files go to the server.

The index is the **index extension of [dotfs](https://github.com/progrium/dotfs/blob/main/docs/9p-dotfs.md)**: the file `.fs/index` at the top of the tree, in the `fsindex 1` format. A dotfs server generates it, and one with dotfs's events extension, `.fs/events`, tells h9 about every change, so the index stays exact for the whole run, even for a tree other clients are writing. A plain 9P server can carry one as an ordinary file, written by a new guest command, `mkindex`, which walks the mounted tree so the qids in it are the server's own. Then each directory is checked against the server the first time it's used, and each file when it's opened. Either way, anything that doesn't match is demoted to plain 9P for the rest of the run, so a stale index costs round trips, never wrong answers. For the root, an index can also be given with `--root-index FILE|URL`, so it can be layered over a server that can't be written to.

## Background

### h9 today

- **[ninep-roots](epoch-0/ninep-roots.md)** mounts a 9P server at `/` through devmnt: a `tcp!` dial string, a unix socket, or, with [websocket-9p](epoch-0/websocket-9p.md), a `ws://` or `wss://` URL, which [schemeless-roots](epoch-0/schemeless-roots.md) lets you write without the scheme.
- **devmnt sends one request per operation and waits for its reply.** Its caller is a guest process, so latency per operation, not bandwidth, is what a remote root costs. devmnt has no cache of its own in drawterm's tree.
- **Startup is mostly metadata.** Before a program does useful work, rc searches `$path`, a Linux program's loader probes library directories, and the program stats and opens its configuration. Each name looked up is a `Twalk`, often followed by a `Tstat`, and a missing name is a full round trip that returns nothing.
- **[overlay](epoch-0/overlay.md)** puts `#O` over the root by default, so the guest's writes to the root land in memory and never reach the server. A root mounted that way is read-only as far as the server is concerned.
- **[dotl](epoch-0/dotl.md)** (draft) puts a translator between devmnt and every 9P connection, which answers some requests from compound .L.Z replies. It caches attributes only until the next mutation, because ZeroFS's trees are mutable, and only within one connection.

### dotfs

[dotfs](https://github.com/progrium/dotfs/blob/main/docs/9p-dotfs.md) is a set of small extensions a file server exposes as synthetic files under `.fs/`: an index (`.fs/index`), a change stream (`.fs/events`), path operations (`.fs/ctl`), and staged commit (`.fs/stage/`). A client finds each by whether its file exists, and a server without `.fs/` is plain 9P. The index extension was written as an iteration on this proposal's first format, `/.h9index`, and fixes what that format couldn't do: every name can be listed, since paths are percent-escaped, the index carries a version per path and a seq for the whole tree, and changes are a stream rather than a rewrite. This proposal uses that format and location, and the events extension when a server has it. It doesn't use path operations or staged commit, which are for writing, nor dotfs's `zstd` encoding (see Open issues).

### The opportunity

A root is a large tree that changes rarely and is read by many runs. Its metadata (names, modes, and lengths) is small next to its contents: a few hundred bytes a name. If h9 had the whole tree's metadata before the program started, nearly every startup round trip but the opens and reads would disappear, and a negative lookup would cost nothing.

The same pattern is proven elsewhere: CernVM-FS ships per-tree catalogs and fetches file contents on demand, Nydus separates an image's "bootstrap" metadata from its data, and eStargz puts a table of contents at the end of each layer. Each of those needs its own server or image format. dotfs keeps plain 9P, and an index file works on any server h9 already mounts.

## Proposal

### The index file

`.fs/index` at the top of the tree, in dotfs's `fsindex 1` format, which [9p-dotfs.md](https://github.com/progrium/dotfs/blob/main/docs/9p-dotfs.md) defines ("Extension 1: index"):

```
fsindex 1 seq 48211
/ d 0755 0 1763491200 48000 - -
/bin d 0775 0 1763491100 47950 - -
/bin/ls f 0775 81920 1763400000 31002 - -
/lib/Tax%202025.pdf f 0644 284113 1763480011 46990 - -
```

A line is a path, escaped, then its type (`d`, `f`, or `l` for a symlink), permission bits in octal, length, mtime, version, content hash, flags, a symlink's target, and optional `key=value` fields, which a reader ignores when it doesn't know them. Lines are sorted by the bytes of the unescaped path, and the first is `/`. What h9 takes from each field:

- **The path** names the entry; any name can be listed, so h9 can answer for every directory, including ones with spaces or non-UTF-8 bytes in their names.
- **The type, mode, length, and mtime** make the entry's `Dir`, with `DMDIR` for a directory.
- **The version** is the path's last change, by the server's seq, or `0` for a read-only tree. 9P's qid.vers is its low 32 bits, as dotfs specifies.
- **The hash and the `p` flag** aren't used yet (see Open issues).
- **A directory flagged `i`** is a nested scope, with its own `.fs/index`; h9 doesn't follow it, and serves it and what's under it by plain 9P.
- **A symlink's directory** is served by plain 9P too, since 9P2000 has no symlinks and devmnt sees whatever the server or translator makes of one.

9P needs three things dotfs's index line doesn't carry: a qid.path, owners, and the mode bits beyond permissions. h9 reads them from `key=value` fields in a `9p.` namespace, which other dotfs readers ignore:

| Field | Meaning | Without it |
| --- | --- | --- |
| `9p.qid=PATH.VERS` | the server's qid.path in hex and qid.vers | qid.path is made from a hash of the path, and qid.vers is the version's low 32 bits |
| `9p.mode=MODE` | the whole 9P mode in octal, with its `DM` bits | `DMDIR` for a directory, and the permission bits |
| `9p.uid=NAME`, `9p.gid=NAME` | the owner and group, escaped | the attach's user name |
| `9p.incomplete=1` | on a directory whose listing isn't whole | the listing is whole |

A dotfs server doesn't know 9P's qids, and needn't. Without `9p.qid`, every qid devmnt sees for an indexed path is the index's: the layer gives the made-up qid.path in its own answers and puts it in the server's replies for that path too (`Rwalk`, `Ropen`, and `Rstat`), so a path has one qid for the whole run, and a bind on it keeps matching after its directory is demoted.

A line h9 can't parse, lines out of order, or a path whose parent isn't an earlier directory fails the whole index, which is then not used (see Failures).

### Building one: `mkindex`

`mkindex [-o FILE] [-s SPEC] [DIR]` is an rc script in [guest-tools](epoch-0/guest-tools.md)' `/bin`, beside `wsmount`. It walks `DIR` (default `/`) with `walk(1)`'s `-e` format and writes an `fsindex 1` index to standard output or FILE, with seq and every version `0`, as for a read-only tree, no hashes or flags, and `9p.qid`, `9p.uid`, and `9p.gid` on every line, and `9p.mode` where the mode has `DM` bits beyond `DMDIR`:

```
h9 --root wss://roots.example/alpine mkindex / >alpine.fsindex
h9 --rc 'wsmount wss://fs.example/data /n/d && mkdir -p /n/d/.fs && mkindex -o /n/d/.fs/index /n/d'
```

It stats the tree through devmnt, so every qid in the index is what the server reports, which matters because h9 later pairs stats from the index with opens from the server. It works on any tree h9 can mount, including one whose host files you can't see. It skips `.fs` and everything in it, and, under the root, the paths the namespace builder binds over it (`/dev`, `/proc`, `/mnt/term`, `/tmp`, and the rest of [policy](../src/policy.zig)'s binds), by walking the mount's own channel through `/srv/root`, attached with `SPEC`, rather than the guest's `/`.

devmnt can't read a directory with a name containing a newline ("bad character in file name"), and `walk` can't print one, so `mkindex` marks such a directory `9p.incomplete=1`, as it does any directory `walk` couldn't open or read, and h9 never answers for it from the index. A name with another control character, or with U+FFFD (a byte that isn't UTF-8, which `walk` can't print as it is), is left out the same way, and its directory marked.

`walk` isn't in [builtin-root](epoch-0/builtin-root.md)'s command set, so this proposal adds it there, so `mkindex` works over a root that has no 9front commands, such as a Linux image, with `--builtin=before`.

### Using one

| Flag | Meaning |
| --- | --- |
| `--root-index FILE\|URL` | Use this index for the 9P root instead of its `.fs/index`. A URL is `https://` or `http://` and is fetched with the root's `--root-ca` and proxy settings. |
| `--index auto\|none` | `auto`, the default, uses an index wherever one is found: `--root-index` for the root, and `.fs/index` on each 9P server h9 mounts. `none` uses none. |
| `--index-cache DIR` | Where compiled indexes are kept. Default: `$XDG_CACHE_HOME/h9/index`, `~/Library/Caches/h9/index` on macOS, `%LOCALAPPDATA%\h9\index` on Windows. |

Indexes apply to the 9P connections h9 makes on the host: the root (`tcp!`, `unix!`, and WebSocket), and the 9P servers a namespace file mounts by dial string or URL, such as `mount -c wss://home.example/u/jeff /usr/jeff`. A namespace-file mount uses the server's `.fs/index`; there's no way yet to give it another (see Open issues). `--root-index` with a host-directory root is a usage error, since `#U` is already local. Mounts the guest makes itself, with `mount` or `wsmount`, don't use an index.

`Machine.Options` gains `index: enum { auto, none }`, `root_index: ?RootIndex`, a union of `path` and `url`, and `index_cache: ?[]const u8`.

### Fetching and caching

When the root, or a namespace file's 9P server, is mounted:

1. **Find the index.** For the root with `--root-index FILE` or `URL`, read it. Otherwise walk to `.fs/index` on the server and stat it, and, at the same time, walk to `.fs/events`. If the index is missing, the mount is ordinary 9P and nothing below happens.
2. **Use the cache.** A server index is cached under the server's address and attach spec, with the index file's qid.path, qid.vers, mtime, and length as its version; a dotfs server's qid.vers is the index's seq, so a changed tree is a new version. If they match the cached entry, h9 uses the compiled form without reading the file. Otherwise it reads the file, compiles it, and replaces the entry. A file or URL index is cached by the SHA-256 of its text; a URL is fetched each run with `If-None-Match` on the last `ETag`, so an unchanged one costs a round trip and no transfer.
3. **Follow or validate** (below), then start the program.

The compiled form is a single file built for mapping into memory: a header with the index's seq, an array of fixed-size entries (qid, mode, length, mtime, version, user indexes, a name's offset and length, the parent, and the first child and child count, with each directory's children contiguous and sorted by name), a user table, a string table, and a SHA-256 trailer over the rest. A walk is a binary search in a directory's children; a stat builds a `Dir` from an entry; a directory read goes through the children in order. Its layout is internal to h9, versioned in its header, and rebuilt from the text whenever the version differs.

The cache directory is created mode 0700, and its files 0600. Entries not used for 30 days are removed when h9 next writes the cache.

### Serving from the index

The index sits between devmnt and the server's connection, as a new kernel device, `#ι`, which devmnt mounts in place of the connection's channel. Like [devhstream](../src/kern/devhstream.c), its logic is Zig (`src/rootindex.zig`), a state machine over 9P messages with no I/O of its own, and the device moves bytes between it, devmnt, and the connection. When [dotl](epoch-0/dotl.md)'s translator exists, the index layer sits above it and still speaks only 9P2000.

It keeps every fid devmnt uses, and each is either **real** (the server has it) or **virtual** (only the index knows it, by its path):

| devmnt sends | With the index |
| --- | --- |
| `Tversion`, `Tauth`, `Tattach` | Forwarded. The attach fid is real. |
| `Twalk` | If every step is a name looked up in an indexed, valid directory, answered locally, after validating the directories on its path that need it, and `newfid` is virtual. A missing name gives the same `Rwalk` or `Rerror` the server would. A walk to `.fs` is always forwarded. Otherwise it's forwarded from the last real fid on the path, after making the starting fid real if it's virtual. |
| `Tstat` | A virtual fid's, or a real fid's whose entry is still valid, answered from the entry. |
| `Topen` of a directory, then `Tread` | Answered locally from the children, as `Dir` records, once the directory is valid. `.fs` is never among them. |
| `Topen` of a file | The fid is made real, by one `Twalk` from the attach fid along its path, and the open is forwarded. The reply's qid is checked against the entry (below). |
| `Tread`, `Twrite` on a real fid | Forwarded. |
| `Tcreate`, `Tremove`, `Twstat` | The fid is made real and the request forwarded. On success, the directory it changed is demoted. |
| `Tclunk` | A virtual fid's is answered locally; a real one's is forwarded. |
| `Tflush` | Forwarded, except for a request still waiting on its fid to be made real or on a directory's validation, which was never sent and is answered locally. |

Making a virtual fid real is one `Twalk`, and devmnt would have sent that walk itself, so an open never costs more round trips than it does without an index. The index never holds or serves file contents.

### Staying correct

The index is a hint, checked against the server, in one of two ways.

**A server with `.fs/events` is followed.** Before it reads the index, h9 opens `.fs/events`, asks for `coalesce`, and reads its first record, `seq C`, the server's current seq. An index at seq M with M ≥ C is then exact, and records after M tell h9 about every later change; records at or below M are dropped, as dotfs's "Bootstrapping with an index" says. An index older than C missed changes h9 can't know about, so it isn't used, with a note under `-v`. While the run lasts, one read on the stream stays outstanding, and each record demotes what it changes: a `put` or `del` its path and its directory, a `mv` both paths and both directories, and a `flags` its path. A `reset`, or the stream ending, demotes the whole index. No directory needs validating, so nothing waits on the server but what would without an index, and other clients' changes during the run are seen as they happen.

**A server without `.fs/events` is validated,** as for an index file on a plain server, or a `--root-index`:

- **Directories are validated once per run, when they're first used.** The root is validated when the server is mounted. Any other indexed directory is validated the first time a request needs the index to answer for it: a walk into or through it, a stat of it, or a read of its listing. The request waits while h9 walks a fid to the directory and stats it, then clunks the fid. A walk validates every directory on its path that isn't yet at once, with up to 64 requests outstanding, so a path costs about two round trips however deep it is, and each directory is validated at most once per run. A directory whose mtime differs from its entry is **demoted**, as is one whose qid.path or qid.vers differs from its `9p.qid`. Adding, removing, or renaming an entry changes a directory's qid.vers on 9front's file servers and its mtime on a Linux one, so a directory that validates has the listing the index says, and the index can answer "file does not exist" for it.
- **The root is checked by its listing when only its stat differs.** Creating `.fs` changes the root's mtime, so an index written into the tree it indexes would always find its root demoted. When the root's stat is all that differs, h9 reads its listing and keeps the root's entries if every name but `.fs` matches the index, serving only the root's own stat from the server.

Either way:

- **Files are checked when they're opened,** from the open's own reply, which carries the qid. A file whose qid.vers differs from its entry's, or, with `9p.qid`, whose qid.path does, is demoted, and devmnt's next stat of it goes to the server.
- **Demoted** means served by plain 9P for the rest of the run: walks into or through a demoted directory are forwarded, and stats of a demoted entry go to the server. Nothing else in the index is affected.
- **Mutations** forwarded through the mount demote what they touch. Under `#O`, the default for roots, the guest's writes don't reach the server at all. A writable mount, such as a home directory, demotes each directory as the guest changes it, and the rest of the index keeps answering.
- **If more than a quarter of the directories validated are demoted,** h9 prints a note under `-v` that the index looks stale, and, for a server index, says to rebuild it with `mkindex`. It doesn't rebuild it itself.

### Mutable trees

An index only stays useful for a tree that changes if the server keeps it current, which is what a dotfs server does: it generates `.fs/index` at its current seq whenever it's read, and streams every change on `.fs/events`, so a mount of a home directory served by dotfs is fast from the first `ls`, and stays exact as other clients write it.

A plain server's index file is only as current as its last `mkindex`. Whatever changed since is caught by validation and demoted, and whatever this run changes is demoted as it happens, so the index never needs to be exactly current to be correct: one that's never rewritten degrades to plain 9P one directory at a time. What a run doesn't see, on such a server, is a change another client makes during the run to a directory this run already validated: a new name stays invisible to walks until the next mount, and a removed one still shows in listings, though opening it fails. That's the same as any client-side cache of a shared tree, and it's the case events exist for. A run that needs to see such changes immediately on a plain server uses `--index none` (see Open issues for a per-mount switch).

What's not checked on a plain server: a file whose contents change in place without a change to its directory shows its old length and mtime to `stat` until it's opened. Its contents are always the server's, since reads always go there. This is the same window as an NFS client's attribute cache, and it only arises when a tree is edited after its index was built and not reindexed.

### What the user sees

- `--print` shows the index in the root's line: `root wss://roots.example/alpine index=/.fs/index`, with `N entries M dirs` for a `--root-index FILE`, or `index=none`.
- `-v` reports how the index was found, and whether it's followed or validated: for a followed index, the seq it follows from, and at the end of the run how many changes demoted what; for a validated one, how long the root's validation took at the mount, and at the end of the run how many directories were checked as they were used and how many were demoted.
- `--check` fetches the index, follows or validates it, and reports the same.

### Failures

An index never makes a root fail to mount that would have mounted without one:

- A `--root-index FILE` that can't be read, or a URL that can't be fetched, is exit 125, as for any root that can't be reached, since you asked for it by name.
- An index that doesn't parse, whose format version or encoding h9 doesn't know, or that's larger than 256 MB, is ignored with a note under `-v`, and the mount is ordinary 9P. So is a cache file whose trailer doesn't match, and a followed index older than the server's seq.
- A cache directory that can't be written means the index is compiled in memory for this run only.

### Performance

Starting rc and running `echo hi`, over a 9front root of 20,368 names served by diod, with a relay adding latency each way, validating directories on first use:

| Latency each way | No index | With an index |
| --- | --- | --- |
| 5 ms | 6.4 s | 1.2 s |
| 25 ms | 14.7 s | 3.2 s |

That run sends the server 357 requests without an index and 74 with one, 44 of them to check the 15 directories it used. On loopback both take 0.05 s. A followed index needs none of the 44.

## Rationale

**Why an index, not a bigger cache in the translator.** A cache filled as the program runs saves the second lookup of a name, not the first, and startup is mostly first lookups. Only something that knows the tree beforehand can answer a first lookup, or a negative one, without asking. An index also tells h9 which directories exist, which is what lets it validate every directory on a walk's path at once even though devmnt can't pipeline.

**Why dotfs's index, not a format of h9's own.** dotfs's index is the same idea with what this proposal's first format lacked: escaped paths, so no directory is left out for one odd name; a version per path; and a change stream beside it, so a mutable tree can be followed rather than revalidated. One format means one `mkindex` output, one parser, and a server written once for dotfs's other clients, such as its sync and on-demand mount, works with h9 unchanged.

**Why `9p.` fields.** dotfs is meant for more than 9P, so its index line has no qid, owners, or 9P mode bits. 9P needs all three, and only `mkindex`, reading through devmnt, knows the server's. `key=value` fields are dotfs's way to extend a line, and other readers ignore them. Making a qid.path up when there's none, and putting it in the server's replies too, is what lets a dotfs server, which has no reason to know 9P's qids, be indexed at all.

**Why follow events rather than validate.** Validating catches what changed before the mount, by a stat per directory used, and misses what changes during the run. A change stream does both, and costs one read outstanding for the run. dotfs's seq makes the start exact: an index at seq M and a stream from M leave no gap.

**Why validate at all, without events.** Without validation an index file would be a promise about a server the client doesn't control. With it, the worst a stale or wrong index does is cost the round trips it would have saved. A future content-addressed root, whose tree is pinned by hash, could skip validation safely; see Open issues.

**Why validate on first use, not all at mount.** Validating every directory at mount is a few round trips, but thousands of small requests: 3,377 for a 9front root of 1,126 directories. A session's start touches a few dozen directories, and validating those as they're used, a path's at once, started about a second sooner at 25 ms each way (see Updates). The cost is up to two round trips the first time each new path is used.

**Why validate directories by stat, not by reading them.** Reading every directory validates every file too, but transfers the tree's metadata on every run, which is what the cache exists to avoid. A directory's stat changes when its listing does on the servers `mkindex` indexes, which is what negative lookups depend on, and file changes are caught at open, which is what reads depend on. A dotfs directory's version doesn't change when its children do, which is one more reason a dotfs server is followed rather than validated.

**Why text on the wire.** `mkindex` is an rc script, which can't sensibly write a binary format, and a text index can be diffed, read, and checked by hand. The binary form exists only in the cache, where its layout can change with h9 without breaking any published index.

**Why build it in the guest.** A host tool would read host files, whose inode numbers aren't the qids a server reports, and couldn't index a remote tree at all. `mkindex` walks the tree through the same devmnt the index will later stand in for.

**Why `--root-index` as well as `.fs/index`.** Many servers can't be written by the person running h9: someone else's export, a read-only ZeroFS replica or checkpoint, or a server that converts images into trees. A separate index can be published anywhere, next to a lockfile or on a CDN, and laid over the same root. It must be a flag, not a namespace-file `bind`, because the index layer is set up when the root is mounted, before the namespace file is replayed.

**Rejected: updating the index in place from the guest's own writes.** A create's reply has the new file's qid but not its parent directory's new version, so the client can't revalidate the directory without a stat, and an index edited by every client would diverge from the server's. Demoting is simpler; a dotfs server's next index, or a plain server's next `mkindex`, restores the directory.

**Why not a content-addressed store now.** dotfs's index can carry each file's hash, which would let h9 serve reads from a local cache shared across runs and roots. That changes how contents are fetched, and isn't needed for the startup win, which is metadata. The format already has room for it.

**Rejected: a well-known file per directory.** Spreading the index over the tree makes every directory cost a read on first use, which is the round trip this proposal removes.

## Compatibility

- **New flags,** `--root-index`, `--index`, and `--index-cache`, and `Machine.Options.index`, `root_index`, and `index_cache`. No existing flag changes.
- **A root or namespace-file mount whose server has `.fs/index` behaves differently by default:** faster, and, on a plain server whose tree was edited without reindexing, with stale lengths and mtimes to `stat` until a file is opened, and with other clients' changes during the run not seen by walks (see Mutable trees). `--index none` restores the old behaviour.
- **A plain server's `.fs`** is an ordinary directory, visible to the guest by name; h9 leaves it out of the listings it serves, as dotfs does.
- **Exit codes:** only an unreadable `--root-index` is new, and it's 125, as for an unreachable root.
- **The built-in root** gains `walk`, about 20 KB per architecture.
- **`third_party/`:** none. devmnt is unchanged; it mounts `#ι`'s channel as it mounts any other.

## Security

The guest can reach nothing new. The index layer only answers requests devmnt would have sent to the server, plus its own reads of `.fs/index` and `.fs/events`, and every open, read, and write still goes to the server under the same attach, user, and auth.

A malicious index, or event stream, from a server or a URL, can show the guest names that don't exist (opening them fails) or hide names that do, the same as a malicious server. It can't make a read return anything but the server's data. The parser is bounded: the 256 MB limit, entries checked against the tree's shape (sorted, and every path's parent an earlier directory), and no field trusted as an offset until checked. An event record only ever demotes.

The cache is per user, mode 0700, and each compiled file is checked against its trailer before use, so a corrupted file is rebuilt rather than trusted. The cache holds the names, owners, and sizes of every file in each indexed tree, which can be sensitive for a private tree. `--index-cache` can point it somewhere else, and deleting the directory is always safe.

A URL index is fetched by h9 on the host, like a WebSocket root, under the root's TLS and proxy settings, and not under the guest's `--net` policy.

## Done criteria

Integration cases tagged `[mount-index]`. The server is the second h9 serving the test root with exportfs, as in ninep-roots' cases, behind a relay that counts T-messages:

- [x] `test "mkindex lists every name in the test root with the server's qids [mount-index]"`
- [x] `test "mkindex escapes names with spaces and marks a directory it can't read incomplete [mount-index]"`
- [x] `test "a root with .fs/index runs /bin/ls [mount-index]"`
- [x] `test "an indexed root sends no Twalk for a missing name in a validated directory [mount-index]"`
- [x] `test "an indexed root sends fewer T-messages than an unindexed one for rc -c echo [mount-index]"`
- [x] `test "--root-index FILE is used over a root without .fs/index [mount-index]"`
- [x] `test "a second run uses the cache and doesn't read .fs/index [mount-index]"`
- [x] `test "a file added after indexing is found, by demoting its directory [mount-index]"`
- [x] `test "a file removed after indexing is not found [mount-index]"`
- [x] `test "a file changed in place reads the server's contents [mount-index]"`
- [x] `test "a malformed index is ignored and the root still mounts [mount-index]"`
- [x] `test "an unreadable --root-index exits 125 [mount-index]"`
- [x] `test "--index none ignores .fs/index [mount-index]"`
- [x] `test "a namespace-file mount of a server with .fs/index uses it [mount-index]"`
- [x] `test "a file created through a writable indexed mount is found by the next walk [mount-index]"`
- [x] `test "a rewritten .fs/index is fetched on the next mount [mount-index]"`
- [x] `test "--root-index with a host-directory root is a usage error [mount-index]"`
- [x] `test "--print shows the index source and entry count [mount-index]"`

Unit tests for `src/rootindex.zig` and the layer, with recorded conversations, since the test server has no `.fs/events`: the `fsindex 1` parser, its escaping, and its limits; walks, stats, and directory reads answered locally; virtual fids made real; flushes; demotion on a mismatched open; qids made up for an index without `9p.qid` and put in the server's replies; and, against a server with `.fs/events`, an index followed from its seq, records demoting what they change, and a stale index or a `reset` ending its use.

Demo: with the test root served over `ws://` behind a relay that adds 50 ms each way, `time h9 --root ws://localhost:8080/9p rc -c 'ls /bin | wc -l'` before and after `mkindex / >/tmp/x.fsindex` and `--root-index /tmp/x.fsindex`, with the T-message counts from `-v`.

## Implementation

1. `walk` in the built-in root's command set.
2. `mkindex` in `src/guest/bin`, with its cases.
3. The `fsindex 1` parser and the compiled form, in `src/rootindex.zig`, with unit tests.
4. The index layer's state machine, with recorded-conversation tests.
5. `#ι` in `src/kern/devhidx.c`, and the root mount in `src/main.zig` and `src/machine.zig` putting it between devmnt and the connection when an index is found.
6. Following `.fs/events`, validation on first use, and demotion.
7. The cache, `--root-index`, `--index`, `--index-cache`, `--print`, `-v`, and `--check`.
8. Namespace-file mounts, through the same layer.
9. URL indexes, through `src/ws.zig`'s HTTP client.
10. MANUAL and SPEC.md.

## Open issues

- **Keeping a followed index current instead of demoting.** A `put` record carries the whole index line, so h9 could apply records to the index rather than demote what they touch, and a long run on a busy tree would keep answering from it. Demoting is simpler and correct; applying needs an index that can change after it's compiled.
- **`zstd`.** dotfs lets a client ask for the index compressed, by writing `accept zstd` to it. That needs the index open for writing, which on a plain server is an ordinary file the write would overwrite, so h9 would have to send it only to a server it knows is dotfs's, such as one with `.fs/events`. The cache makes a compressed fetch matter only when the index changes.
- **Nested scopes.** h9 serves a directory flagged `i` by plain 9P. Reading its `.fs/index` the first time something under it is needed, as dotfs suggests, would cover very large or busy subtrees, and a different server mounted under a path.
- **Hashes and prefetch.** A file's hash could key a host cache of contents shared across runs and roots, and the `p` flag could fill it ahead of the program's reads.
- **`9p.` fields in dotfs.** Whether the `9p.` fields should be written down in dotfs itself, so a dotfs server that knows its 9P qids and owners can send them.
- **Validating ahead.** Without events a directory is validated on first use, so a program that walks into many new directories one at a time waits about two round trips for each. Validating a directory's subdirectories along with it, or the directories a previous run used, could hide some of that, at the cost of requests a run may not need.
- **Per-mount control.** A namespace-file mount can't name an index other than its server's, or turn indexing off for itself alone, because `mount`'s flags are 9front's. A spec suffix or an h9-only flag would do it. The guest's own `mount` and `wsmount` could use the layer too, once roots prove it.
- **Writing the index for ZeroFS.** ZeroFS doesn't write `.fs/index` itself. A dotfs gateway in front of it, or a periodic `mkindex`, would; which one is a deployment choice, not part of h9.
- **The browser host** has no cache directory. The embedder could pass the compiled index in, or h9-web could keep it in the Cache API.
- **Skipping validation.** A root pinned by content hash can't change, so its index needs no checking, but 9P has no way to say a tree is pinned. That belongs with a content-addressed root kind, which this format is meant to grow into.
- **The device's letter.** `#ι` is a placeholder.

## Updates

- 2026-11-14: Implemented on the `mount-index` branch, with all 18 cases passing on the native backend (amd64) and the layer's own unit tests (`src/rootindex/layer_test.zig`). Refinements and decisions made along the way:
  - **The root is checked by its listing when only its stat differs.** Writing `/.h9index` changes the root directory's mtime, and on most servers its qid.vers, so a root indexed before its index was written would always be demoted. When the root's stat is all that differs, the layer reads its listing and keeps the root's entries if every name and qid matches the index, serving only the root's own stat from the server.
  - **A server index's version is qid.path, qid.vers, mtime, and length,** not just the qid and mtime, so a rewrite within the same second is still seen on a server whose qid.vers or length changes with it.
  - **`Tflush` is always forwarded,** except for a request still waiting on its fid to be made real, which was never sent and is answered locally. Answering a flush locally when the request it names was answered locally let its `Rflush` overtake an earlier flush's on the server, and devmnt, which drops a chain of flushes once the last is answered, printed "unexpected reply tag" at exit on a slow writable mount.
  - **`#ι` is masked, after the namespace file.** A guest conversation could read and write the host's index cache: read another tree's cached index by naming its key, or plant one for a later run. It's masked once `--ns` is replayed, since its mounts go through `#ι`, and h9 reads a conversation's status at the end of the run through a leaf rather than a chan.
  - **`-v` is new, with `--verbose`.** h9 had long flags only; `-v` is the one short flag, accepted only before the program. Its last note separates the requests that found and checked the index from devmnt's own: over the 9P test server, `ls /bin/ls` sent 205 requests from devmnt and 16 of them reached the server, besides 3473 pipelined ones that checked 1160 directories, and ran in 1.6 s against 2.4 s without the index.
  - **`--print` counts only a `--root-index` FILE.** It connects to nothing, so a server's `/.h9index` shows as `index=/.h9index`, and a URL without counts.
  - **`mkindex` takes `-s SPEC`,** since `/srv/root` is attached afresh and a root with `--root-spec` would otherwise attach the server's default tree. Its `!unindexed` lines come after the entries, since each must name an earlier directory. Over 9P, devmnt fails the whole directory read when a name has a newline ("bad character in file name"), so `walk` warns and lists nothing in it; `mkindex` marks a directory `walk` couldn't open or read, which covers that case.
  - **The cases use a small tree** copied from the test root (rc, the commands `mkindex` and the cases run, rcmain, the mount points, and `/lib/x`), served the same way, since `mkindex` over the whole test root through the test server takes minutes. Each case keeps its own `--index-cache`.
  - **`walk` joined the slim set** ([multicall](epoch-0/multicall.md)), with a corpus entry; the slim tree couldn't be rebuilt here, so the box's size wasn't measured again.
  - The demo, over `ws://` with 50 ms each way, hasn't been run yet.
- 2026-11-14: **Directories are validated on first use,** not all at mount, which closes the lazy-validation open issue. Checking all 1,126 directories of a 9front root at mount took 3,377 requests, and at 25 ms each way `echo hi` started in 4.3 s, against 3.2 s validating on first use (see Performance). `-v`'s summary of the validation moved to the end of the run, since that's when it's known.
- 2026-11-21: **Rebased on dotfs's index extension.** The index is now `.fs/index` in dotfs's `fsindex 1` format ([9p-dotfs.md](https://github.com/progrium/dotfs/blob/main/docs/9p-dotfs.md)), not `/.h9index` in this proposal's own, so one format serves h9, dotfs's other clients, and dotfs servers. Paths are escaped, so there's no `!unindexed`; 9P's qid, owners, and mode bits travel in `9p.` fields, with a qid.path made up when there's none; and a server with `.fs/events` is followed from the index's seq instead of validated. The Done criteria are unchecked until the branch matches.
- 2026-11-21: **The branch matches.** All 18 cases pass again on the native backend (amd64), with the layer's unit tests, including ones against a server with `.fs/events`, since the test server has none. Notes on the implementation:
  - **The compiled form gained each entry's version and the index's seq** (72-byte entries, compiled version 2), so a followed index can compare the server's seq, and an open's qid.vers can be checked against the version.
  - **Events are opened read-write to ask for `coalesce`,** and read-only when the server refuses, and the index waits for the stream's first record before serving. A record past the index's seq demotes the paths it names; one at or before it is already in the index. A `reset`, or the stream ending, stops the index's use for the rest of the run, with a note under `-v`.
  - **Without `9p.qid`, a directory is validated by its mtime alone,** since its made-up qid can't be compared with the server's, and the layer rewrites the server's qid for an indexed path in `Rwalk`, `Ropen`, and `Rstat`, and keeps it for a demoted directory's children it still knows.
  - **`mkindex` reads `walk`'s warnings whole.** A warning about a name with a newline goes on to the next line, which `mkindex` once took for the rest of a record and dropped the entry before it with.
