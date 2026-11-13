---
slug: kernel-serve
title: A 9P server in the kernel
status: draft
created: 2026-11-13
authors: [progrium]
depends: [serve, dotl]
areas: [kern, sandbox, web]
branch: []
---

# Proposal: A 9P server in the kernel

## Abstract

h9's kernel gets its own 9P2000 server, `src/kern/kserve.c`, and [serve](serve.md)'s per-connection path uses it in place of running 9front's `exportfs` as a guest process. Each connection is served by kernel coroutines (threads on native hosts) that work on kernel channels directly: a fid holds a `Chan`, walks and opens go through `namec`'s pieces and the devices, and directory reads of unions go through the same code `sysread` uses. So access rules, the policy hooks, and the namespace a client sees are unchanged. Serving no longer forks a guest process per connection or per blocking request, no longer needs `/bin/exportfs` from a root or the built-in box, no longer counts against `--pids`, and works on any build with a kernel, including the web host and [namespace-kernel](namespace-kernel.md), which has no guest processes at all. A connection's attach name can choose which namespace it's served from, which is how namespace-kernel serves one namespace per task.

## Background

- **How serving works today** ([serve](serve.md), Each connection): a listener accepts a stream, the dialect slot ([dotl](dotl.md)) passes 9P2000 through or translates 9P2000.L, and the machine's server Proc forks a Proc that execs `exportfs -r PATH` (`-R` under `--write=none`) on the stream. exportfs forks one more process for each request that blocks. Serving processes are counted under `--pids` separately from the program's, with 8 per connection and 32 connections (`serve.max_conns`, `serve.conn_procs`), and exportfs's memory counts under `--memory`.
- **Why serve chose exportfs.** Its Rationale: exportfs is "already correct for every device the machine has", and "it serves through the guest's namespace, so devfs's access rules, `--read-deny`, and the write policy hold without a second implementation. Serving from Zig straight off kernel channels would save a process and a copy per message, but it would be a second 9P server to keep correct."
- **What that costs.**
  - A guest process, and often several, per client. The serving share of `--pids` and memory exists only because of that.
  - A dependency on finding an exportfs binary: `/bin/exportfs`, or `#Hroot/$cputype/bin/exportfs` from [builtin-root](builtin-root.md). A build without a 9front box for the machine's architecture can't serve.
  - Exportfs serves the namespace of the process it runs in, so one connection gets one namespace, fixed when serve's server Proc copies it.
  - Nothing can serve where there are no guest processes. [namespace-kernel](namespace-kernel.md) is a kernel build with none.
- **Kernel-side serving already exists in drawterm.** `third_party/drawterm/exportfs/` (about 1.2k lines) is the exportfs drawterm runs in its own kernel, on kprocs, to export `/mnt/term` to a cpu server (`cpu.c`). h9's build leaves it out. It's path-based, as 9front's exportfs is: a fid is a path string, and each walk is a `dirstat` of the joined path. Its state (`fhash`, `fidfree`, `root`) is file-scope globals, so it serves one connection per process.
- **The checks are in the kernel, not in exportfs.** devfs's `h9_fs_check` (`src/kern/fscheck.c`), `--read-deny`, overlay's write rules, and the device mask all run inside channel operations. exportfs reaches them only because it makes system calls that end in those operations. A server in the kernel that makes the same channel operations reaches the same checks.

## Proposal

### The server

`src/kern/kserve.c` serves one 9P2000 connection on a channel (a devhstream stream's data channel, or any channel that reads and writes whole 9P messages).

- **Fids hold channels.** `Tattach` gives the fid a clone of the chosen namespace's root channel (see Namespaces). `Twalk` clones the fid's channel and walks only the new elements with chan.c's `walk()`, which crosses mounts as `namec` does and reports how far a partial walk got, so `Rwalk`'s qids come straight from it. Through devmnt that's one upstream `Twalk`, not a walk from the root. A fid never holds a path string, so a rename by another client doesn't change what an open fid names, and a name that's removed and made again is a different file.
- **namec's special cases, reused.** Some of the kernel's resolution lives in `namec`, not `walk()`: creating in a union (finding the `MCREATE` member), `..` back across a mount, and opening a mount point. For those, the worker sets `up->dot` to the fid's channel and calls `namec` with the last element as a relative name (`Acreate` for `Tcreate`, `Aopen` for `Topen` when the fid's channel is a mount point), so drawterm's own handling runs and isn't copied.
- **Operations** go to the channel's device as `sysfile.c`'s wrappers do: `Topen` and `Tcreate` through the device's `open` and `create` with the same mode checks (`openmode`, `DMEXCL`, `ORCLOSE`), `Tread` and `Twrite` through `devtab[c->type]->read` and `write`, with directory reads of a union through `unionread` and of anything else packed as `Dir`s, `Tstat` and `Twstat` through `stat` and `wstat`, `Tremove` through `remove`, and `Tclunk` through `cclose`.
- **Blocking.** Each request runs on a worker from a small per-connection pool of kernel processes (coroutines on the web host), so a read that blocks on a pipe doesn't hold up the connection. `Tflush` interrupts the worker running the flushed tag, which fails its request with "interrupted" as a note does, and answers `Rflush` after the worker's reply, as 9P requires.
- **Errors** are the kernel's error strings, as exportfs returns them.
- **Seam rules.** The server is C, under `waserror`, because it lives between devices and channels. Its only Zig is the leaf that hands it a connection.

### Namespaces

A Proc's namespace is its Pgrp, plus its `slash` and `dot`. A connection is served from a *source*:

- **The plan's namespace,** copied once before the program starts, as serve does now: the server's Pgrp is a `pgrpcpy` of the first Proc's, with `/net` unmounted unless `--serve-net` is given. Every attach on every connection gets it. This is the only source in h9 machines, and it makes `--serve` behave exactly as it does today.
- **Named namespaces,** for [namespace-kernel](namespace-kernel.md): the attach name selects one of its namespaces by id, and `Tattach` of an unknown or freed id fails with "no such namespace". The source is an interface (`lookup(aname) → Pgrp, slash`), so this proposal doesn't depend on that one.

Each request runs with `up->pgrp`, `slash`, and `dot` set to its fid's namespace and the machine's user, so device code that reads `up` sees the same thing exportfs's process would have.

### Policy

- **Read-only serving** (`--write=none`, exportfs's `-R`): `Topen` with a write mode, `Tcreate`, `Tremove`, and `Twstat` fail with "permission denied", in the server, before reaching the device.
- **`-r PATH`** (serve's `--serve-root`): the attach root is that path walked from the source's root, and `..` stops there, as exportfs's `-r` does.
- **Caps.** At most 32 connections, as now. Each holds at most 4096 fids, since every fid pins a kernel channel, and for a fid in a mounted tree an upstream fid too; a walk to a new fid past that fails with "too many fids". Each has at most 8 requests outstanding at once; past that, the next request waits for a worker rather than failing, since workers are cheap and waiting is what a slow server does. There's no serving share of `--pids`, since nothing is a guest process. Buffers count against `--memory` as kernel allocations do.
- **The user.** Every client acts as the machine's user, and `Tattach`'s `uname` isn't checked, as with exportfs.

### serve's per-connection path

Step 3 of serve's Each connection becomes: the server Proc starts a kserve connection on the stream's channel. The dialect slot is unchanged: a 9P2000.L client goes through dotl's server side, whose 9P2000 output goes to kserve instead of exportfs. `--print`'s `serve` heading says `kernel` where it now names the exportfs path. Exportfs stays in the built-in box for guests that want to run it themselves.

## Rationale

**A second 9P server to keep correct.** That's serve's objection, and it holds: kserve is new code with 9P's subtle parts (flush ordering, fid reuse, directory offsets). What changes the trade is that h9 now needs a server where no guest process can run ([namespace-kernel](namespace-kernel.md), and port serving on the web host from [port-streams](port-streams.md)), and that one server can't pick a namespace per attach as exportfs is built. The access rules stay in one implementation, the kernel's, because kserve calls the same channel operations exportfs's system calls end in.

**Channels, not paths.** drawterm's exportfs is path-based, as 9front's is: a fid is a name node, each walk step is a `dirstat` of the joined path from the root, and an open opens the path again. Porting it is less new code (make its globals per connection), its fids are cheap, and an idle one holds nothing upstream. But every operation re-resolves the whole path through the mount table, which over a devmnt mount means upstream walks from the root each time with no cache; identity is by name, so a file renamed under an open fid is lost and a recreated name silently becomes the new file; and an opened file with no path can't be named. A channel per fid gives exact identity and short walks, and it's what [dotl](dotl.md) said serving `9P2000.L.Z`'s `Trebind` would need: a fid that survives by identity, not name. Its costs are a pinned channel per fid, bounded by the fid cap, and namec's special cases, which the worker reuses through `up->dot` rather than reimplementing.

**Not in Zig.** The server sits between channels and devices, where errors are `waserror`/`error`. Zig code can't sit between a `waserror` and an `error` (SPEC.md, seam rule 1), so the server would be all leaf calls back into C.

**Waiting, not failing, past the outstanding cap.** exportfs failed requests past its 8 processes because each was a guest process counted against a limit. A kserve worker is a coroutine or a thread from a pool, so a client that pipelines gets backpressure, not errors.

**Keeping exportfs around.** It's still 9front's tool, and guests use it with `aux/listen1` and `srvfs`. Only serve stops depending on it.

## Compatibility

- **`--serve`'s behaviour** to clients is unchanged: the same namespace, `/net` rules, read-only rule, dialects, and errors. A client that relied on a blocking request failing past 8 outstanding now waits.
- **Limits:** the plan's `limits` line drops `(+N serving)`, and `--pids` covers only the program.
- **`--print`:** `serve` shows `kernel` instead of an exportfs path.
- **builtin-root:** serving no longer needs its box's `exportfs`, so a build that embeds no box for an architecture can still serve.
- **serve:** this changes step 3 of its Each connection and its "Which exportfs", "Per connection", and "Processes" paragraphs. serve stays implemented; SPEC.md's serving section is updated, and serve gets an Updates note pointing here.
- **`third_party/`:** unchanged. drawterm's exportfs stays out of the build.

## Security

- **No new reach.** A client sees what it saw through exportfs: the source namespace, under the kernel's checks, which are the same channel operations.
- **New attack surface:** kserve parses 9P from untrusted clients in the kernel, where exportfs parsed it in a guest process whose crash killed only itself. A malformed message must fail the connection, never the machine. kserve uses drawterm's `convM2S`, which bounds-checks, and every fid lookup, count, and offset is validated before use. The cases include a fuzzed stream.
- **Resource use** moves from guest processes to kernel workers and buffers, bounded by the connection and outstanding-request caps and by `--memory`.
- **Flush.** A `Tflush` interrupts only the worker for its connection's tag, never another connection's.

## Done criteria

- [ ] `h9 --serve unix!/tmp/h9.sock` serves with no `/bin/exportfs` anywhere in the namespace, and 9front's `mount` lists `/bin` through it.
- [ ] The serve and dotl integration cases pass unchanged on kserve.
- [ ] Cases tagged `[kernel-serve]`:
  - `test "serving runs no guest process [kernel-serve]"`
  - `test "a blocking read doesn't hold up the connection [kernel-serve]"`
  - `test "Tflush interrupts a blocked read and answers after its reply [kernel-serve]"`
  - `test "an open fid survives a rename by another client [kernel-serve]"`
  - `test "create in a union lands in the MCREATE member [kernel-serve]"`
  - `test "walking .. back across a mount matches namec [kernel-serve]"`
  - `test "a walk past the fid cap fails without hurting other fids [kernel-serve]"`
  - `test "--write=none refuses writes in the server [kernel-serve]"`
  - `test "--serve-root stops .. at the attach root [kernel-serve]"`
  - `test "a union directory reads the same as through exportfs [kernel-serve]"`
  - `test "a fuzzed 9P stream fails the connection, not the machine [kernel-serve]"`
  - `test "--pids no longer counts serving [kernel-serve]"`
- [ ] SPEC.md describes kserve, and serve has an Updates note.

## Implementation

1. `kserve.c`: attach, walk, open, read, write, stat, clunk, over the plan's namespace, with one worker. Run serve's cases against it behind a build flag.
2. Workers per connection, flush, create, remove, wstat, union reads, the policy rules.
3. Switch serve's per-connection path to kserve, drop the serving share of `--pids`, update `--print` and the plan's limits line.
4. The named-namespace source interface, for [namespace-kernel](namespace-kernel.md).
5. SPEC.md and serve's Updates note.

## Open issues

- **Serving `9P2000.L.Z`.** dotl answers `.L.Z` with `.L` because `Trebind` needs open by inode. kserve's channel-held fids may be enough to rebind by the qid a fid had, at least within a run. Its compounds (`Twalkgetattr`, `Treaddirattr`, `Tlopenatread`) are easy once the server is ours. A proposal of its own, after this one.
- **Live namespaces in h9 machines.** serve's Open issues ask for exporting the program's live namespace, or one task's. With a source interface, that's a second source, not a second server.
