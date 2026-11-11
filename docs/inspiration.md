# What to build with h9

The [recipes](recipes.md) are one-liners. This guide is about larger
systems that use h9 as a building block: an h9 machine treated the way a
web app treats a database connection, as a cheap, isolated unit whose whole
world is a namespace you compose from 9P servers.

None of these exist yet. Each idea says what it is, why h9 makes it newly
practical, a rough sketch of how to build it, and the proposals it builds
on. Proposal statuses change often, so check
[design/STATUS.md](../design/STATUS.md) for the current state.

## Contents

- [The primitives these lean on](#the-primitives-these-lean-on)
- Trust and access
  1. [Agent workspaces where credentials are file servers](#1-agent-workspaces-where-credentials-are-file-servers)
  2. [Compute-to-data rooms](#2-compute-to-data-rooms)
  3. [Namespaces instead of a VPN](#3-namespaces-instead-of-a-vpn)
  4. [A dependency firewall](#4-a-dependency-firewall)
- Builds and execution
  5. [Builds keyed by what they read](#5-builds-keyed-by-what-they-read)
  6. [Speculative fan-out](#6-speculative-fan-out)
  7. [A function platform where bindings are mounts](#7-a-function-platform-where-bindings-are-mounts)
  8. [A flight recorder](#8-a-flight-recorder)
- Distribution
  9. [Packages with no install step](#9-packages-with-no-install-step)
  10. [Executable archives](#10-executable-archives)
- Personal and distributed computing
  11. [A portable personal namespace](#11-a-portable-personal-namespace)
  12. [Borrow compute, keep your files](#12-borrow-compute-keep-your-files)
  13. [Browser workspaces with no backend](#13-browser-workspaces-with-no-backend)
- Extending applications
  14. [A plugin runtime where the app is a file tree](#14-a-plugin-runtime-where-the-app-is-a-file-tree)
- [Where to start](#where-to-start)

## The primitives these lean on

The ideas rest on a handful of properties that are rare together:

- **A process starts like a native process.** There's no image, boot or
  guest kernel, yet guest code runs under a hypervisor (HVF, KVM, WHP), the
  native backend, or the emulator.
- **The namespace is the whole interface.** Per-process mount tables, union
  binds, `/srv` and `--ns` files make a program's world a small declarative
  plan that `--print` shows and you can diff.
- **Anything that speaks 9P can be the world.** Roots and mounts over TCP,
  unix sockets and WebSocket, in 9P2000 or 9P2000.L, so a file server in any
  language, anywhere, becomes a filesystem for the guest.
- **A machine can be served.** `--serve` exports the machine's namespace
  over the same transports, so other machines, Linux clients and browsers
  can mount it.
- **Writes can be thrown away.** `--write=ephemeral` and the `#O` overlay
  keep changes in memory, and the host never sees them unless you harvest
  them.
- **Policy is compiled, not configured.** Network modes and `--net-allow`
  patterns, memory, process and CPU caps, timeouts, and read-deny paths.
- **It's a library.** `h9.Machine` runs several machines in one process,
  with stdio as plain Zig streams ([embedding](embedding.md)).
- **It runs on macOS, Linux, Windows and in the browser.**
- **A small, single boundary.** A 9front program has about 40 syscalls,
  served by drawterm's kernel in the host, so every effect it has crosses
  one narrow, inspectable place.

## Trust and access

### 1. Agent workspaces where credentials are file servers

An execution substrate for AI agents in which the agent never holds a
secret or a socket. Every capability it has is a directory mounted into its
machine by a broker, and every change it makes lands in an overlay that a
person or a policy reviews before it touches anything real.

**Why h9.** Containers give an agent a whole Linux and then try to take
things away. h9 starts from nothing and adds mounts, so the list of
capabilities *is* the `--print` plan. Startup is process-fast, so a machine
per tool call is affordable. `#O` gives the review step for free, and
`--net-allow` pins egress to the broker alone. The Linux personality means
the agent's ordinary tools run too.

**Sketch.**

- A daemon embeds `h9.Machine` and keeps a pool of machines (one HVF
  machine per host process on a Mac, so a few worker processes; KVM or the
  native backend on Linux).
- A broker 9P server, in any language, is the only thing the agent can
  reach. It serves synthetic trees: `/n/gh/repos/acme/web/pulls/new` (write
  a body, read back a URL), `/n/db/query` (write SQL, read rows, through a
  read-only role), `/n/llm/ctl`. The broker holds the tokens and logs every
  write as an audit record.
- The repository is bound at `/mnt/term/cwd` under `--write=ephemeral`.
  When the task ends, the daemon turns the overlay into a patch or a pull
  request, gated by policy.
- A task's capabilities are a namespace file checked into the repository,
  so they're reviewed like code. An agent that wants to delegate starts a
  child machine whose policy can only be narrower than its own.

**Builds on:** [ninep-roots](../design/ninep-roots.md),
[devsrv](../design/devsrv.md),
[ephemeral-writes](../design/ephemeral-writes.md),
[net-policy](../design/net-policy.md),
[linux-personality](../design/linux-personality.md). Would pull forward
[host-srv](../design/host-srv.md) (hand the broker's connection in
pre-dialed), [overlay-export](../design/overlay-export.md) (harvest the
changes), [credential-helpers](../design/credential-helpers.md) and
[child-machines](../design/child-machines.md).

### 2. Compute-to-data rooms

A way for a data owner to let outsiders run code against sensitive data
without the data leaving. The analyst submits a program; it runs where the
data lives, sees the data read-only, has no network, and can only emit
results through an `/out` file server that enforces release rules: row
thresholds, aggregates only, size caps, or human approval.

**Why h9.** Clean rooms today are either SQL-only or heavyweight VM
enclaves. h9's sandbox is a printable, diffable plan, so the owner can
publish exactly what a job could see and the analyst can check it. The
only way out is a 9P server the owner wrote, so release policy is ordinary
code.

**Sketch.**

- A job service embeds h9 with `--profile=tight`, the dataset as
  `--readable` (or a 9P server that filters rows per attach user), and
  `/out` as a posted 9P server.
- The `/out` server buffers writes, checks them against the release rules,
  and queues anything borderline for approval. Only approved bytes reach
  the analyst.
- Each run's `--print` plan, input hashes and released output are signed
  into an audit log, so either side can prove what happened.
- Later, KVM on attested hosts (SEV-SNP, TDX) could make the plan part of a
  remote attestation.

**Builds on:** [net-policy](../design/net-policy.md),
[ninep-roots](../design/ninep-roots.md). Would pull forward
[host-srv](../design/host-srv.md) (post `/out`),
[root-auth](../design/root-auth.md) (per-analyst attaches),
[host-sandbox](../design/host-sandbox.md) and
[hide-host-paths](../design/hide-host-paths.md).

### 3. Namespaces instead of a VPN

Access to internal systems granted as a namespace rather than a network. A
contractor, an on-call engineer or a CI job gets an h9 session whose `/n`
holds exactly the internal services their role allows (`/n/logs/prod`,
`/n/db/readonly`, `/n/deploy/staging`), mounted over authenticated
`wss://` through the ordinary HTTPS proxy. There's no network route into
the company at all.

**Why h9.** A VPN grants a network and then fights to narrow it.
Zero-trust proxies narrow access per HTTP app but leave command-line tools
and databases awkward. A 9P mount is per service by nature, works for any
tool that reads files, and crosses corporate proxies as a WebSocket. Mounts
in a namespace file are made by h9 on the host, so the session itself can
run with `--net=disable` and reach nothing that isn't mounted. Revoking
access is unmounting, and auditing is logging 9P messages at the gateway.

**Sketch.**

- A gateway signs the user in (OIDC), looks up their role, and returns a
  namespace file of `wss://` mounts.
- Each internal service gets a small 9P adapter: logs as files you can
  tail, a database as `query` and `result` files on a read-only role,
  deploys as `ctl` files the adapter turns into audited API calls.
- The client is `h9 --ns role.ns --net=disable rc` locally, or the same
  namespace in a browser tab for zero-install break-glass access.
- A session recording is a log of 9P traffic, far smaller and easier to
  search than terminal video.

**Builds on:** [websocket-9p](../design/websocket-9p.md),
[net-policy](../design/net-policy.md),
[browser-host](../design/browser-host.md). Would pull forward
[credential-helpers](../design/credential-helpers.md) (short-lived tokens,
none in the namespace file) and [root-auth](../design/root-auth.md).

### 4. A dependency firewall

A service that runs every third-party install script, build step and test
suite in an instrumented machine, and produces a behavioural manifest per
package version: files read, files written, hosts dialled, processes
started. A new version that suddenly reads `~/.ssh` or dials a new host is
blocked before it reaches a laptop or CI.

**Why h9.** Supply-chain scanners mostly read source, or watch syscalls with
eBPF on a real Linux, where a hostile script sees and can probe a real
host. In h9 the script's whole world is one you serve: decoy home
directories as a 9P tree, `--net-allow` limited to the registry,
`--read-deny` on secrets, and every access is a 9P message or a network
lookup you can log. Manifests diff cleanly between versions because the
namespace is identical on every run.

**Sketch.**

- A worker pulls new versions from npm, PyPI and crates mirrors and runs
  their install and test steps as Linux programs, with a honeypot home
  (`/n/decoy/home`, holding fake tokens that alert when read).
- A logging 9P root and the net policy's lookups record every access;
  `--trace` covers the rest.
- Manifests are stored per version, and a diff policy ("new network
  destination", "reads outside its own tree") flags or blocks the version
  in an internal registry proxy.
- Developers run the same sandbox locally as a wrapper for the install
  command.

**Builds on:** [linux-personality](../design/linux-personality.md),
[linux-net](../design/linux-net.md),
[linux-threads](../design/linux-threads.md),
[net-policy](../design/net-policy.md), [ninep-roots](../design/ninep-roots.md).
Would pull forward [cow-fork](../design/cow-fork.md), since package managers
fork large processes.

## Builds and execution

### 5. Builds keyed by what they read

A remote build and test cache that needs no declared inputs. Every file a
build step touches arrives as a 9P message, so the system records the exact
set of files and versions the step read, and that set becomes its cache
key. It's Bazel-grade hermeticity for `mk`, `make`, shell scripts or Go
tests, without BUILD files.

**Why h9.** Bazel and Nix make you declare inputs because a Linux process
can reach anything. In h9 a process can reach only its namespace, and the
root can be a server you wrote, so the record of reads is complete by
construction. Outputs land in `#O` and are harvested cleanly, and the same
step runs on a Mac laptop, a Linux worker or the emulator.

**Sketch.**

- A content-addressed 9P server fronts a blob store. Its attach spec names
  a tree hash (`--root-spec tree:ab12…`), and it logs `(path, qid.version,
  hash)` for every walk and read, per session.
- A step's first run records its read set. The key is a hash of the
  command, the environment and that set. Later runs check the cache by
  re-validating the read set against the new tree, as Bazel's action cache
  does, but discovered rather than declared.
- Workers attach with `--root wss://cas.example/9p` and
  `--write=ephemeral`. The coordinator collects the overlay as outputs and
  stores them back as blobs.
- The `--print` plan and the read log together are a provenance record
  (SLSA-style) for free.

**Builds on:** [ninep-roots](../design/ninep-roots.md),
[websocket-9p](../design/websocket-9p.md),
[overlay](../design/overlay.md), [kvm](../design/kvm.md),
[serve](../design/serve.md). Would pull forward
[overlay-export](../design/overlay-export.md) and
[mount-index](../design/mount-index.md) (answer walks and stats without a
round trip each).

### 6. Speculative fan-out

A search engine over program runs. Start from one base tree, launch N
machines that each try something different (a candidate patch, a config
value, a migration order, an agent's alternative plan), each in its own
overlay, then score the results and keep only the winner's changes. The
losers cost nothing to discard.

**Why h9.** Doing this with containers means N copies of a filesystem or a
copy-on-write snapshot driver, plus seconds of startup each. With h9 the
base is one read-only tree that every machine shares, the divergence is
`#O` in memory, and a machine starts like a process. That's cheap enough to
fan out per decision, not per nightly job: the substrate best-of-N agent
loops, autotuners and property-based tests all want.

**Sketch.**

- A coordinator embeds h9 and takes a base (a host directory or a 9P root)
  and a list of variants, each a namespace file plus a command.
- Each variant runs under `--write=ephemeral` with its own caps. A scorer
  (tests passing, benchmark time, a model's judgement) reads each machine's
  results from an `/out` file server.
- The winner's overlay is exported as a patch, or applied to the base. With
  `--serve`, the coordinator mounts every live variant side by side at
  `/n/variant/N` and diffs them with ordinary tools.
- It nests: a variant can fan out again, giving tree search over program
  states.

**Builds on:** [ephemeral-writes](../design/ephemeral-writes.md),
[overlay](../design/overlay.md), [serve](../design/serve.md),
[embedding](embedding.md). Would pull forward
[overlay-export](../design/overlay-export.md) and
[child-machines](../design/child-machines.md) (a variant fans out from
inside its own machine).

### 7. A function platform where bindings are mounts

A serverless runtime in which each invocation is a fresh machine, and
everything the function can touch (request, response, key-value store,
queues, other services) is a file. A deployment's bindings, in the
Cloudflare Workers sense, are literally the lines of its namespace file.

**Why h9.** Firecracker isolates well but boots a kernel and needs an image
per function. V8 isolates start fast but run only JavaScript and wasm. h9
sits between: hypervisor isolation, process-speed start, and real native
binaries, whether 9front C, Go with `GOOS=plan9`, or Linux programs. Its
policy flags (`--memory`, `--timeout`, `--pids`, `--net-allow`) are exactly
a function platform's limits.

**Sketch.**

- A front door embeds h9, accepts HTTP, starts a machine per request from a
  warm pool, and serves a per-request tree: `/req/{method,url,headers,body}`
  and `/resp/{status,headers,body}`. Streaming bodies are reads and writes.
- Platform services are 9P servers posted in `/srv` before the function
  starts: `kv`, `queue`, `blob`, `secrets`. The deploy manifest is a
  namespace file, so adding a binding is adding a mount.
- Code is a package tree ([idea 9](#9-packages-with-no-install-step)),
  mounted read-only; scratch space is the private `/tmp`.
- Actors in the style of Durable Objects fall out: a long-lived machine
  whose state is its own ramfs, reachable through `/srv` or `--serve`.

**Builds on:** [devsrv](../design/devsrv.md),
[net-policy](../design/net-policy.md), [go-compat](../design/go-compat.md),
[linux-personality](../design/linux-personality.md),
[kvm](../design/kvm.md), [serve](../design/serve.md). Would pull forward
[host-srv](../design/host-srv.md).

### 8. A flight recorder

A service that records every nondeterministic input a program receives and
replays the run exactly: for flaky CI tests, capturing production
incidents, and time-travel debugging.

**Why h9.** rr works on Linux by intercepting a large syscall surface with
performance counters and ptrace. In h9 the kernel already lives in the
host, and every input to a 9front program crosses about 40 syscalls: time
comes from the `bintime` and `time` hooks, randomness from one function,
files and network from 9P and devip. `--trace` already prints that
boundary. Recording means logging results at that one choke point, and
replay means serving them back instead of making the real call.

**Sketch.**

- A recording mode in the syscall dispatcher logs each call's results, the
  bytes it copied into guest memory, and where notes were delivered
  (counted by syscall).
- Replay serves the log back. With `--cpus 1` on the emulator, scheduling
  is deterministic too. With several CPUs, record the order of syscall
  entries across processes as a total order, as rr does for threads.
- In CI, every test runs recorded. A failing run uploads its log, and a
  developer replays it locally, on any OS, with a debugger on the emulator.
- The same log is a precise behavioural diff between two versions of a
  program.

**Builds on:** the [baseline](../design/baseline.md)'s syscall dispatch and
`--trace`, and the emulator. [hcpu](../design/hcpu.md)'s interpreter tier
is a natural place for single-stepping and reverse execution. Needs a
proposal of its own.

## Distribution

### 9. Packages with no install step

Software distribution where installing a package means adding a line to a
namespace file. Packages are immutable trees on a 9P server, and a
program's `/bin` and `/lib` are a union of exactly the versions it asked
for, fetched lazily over WebSocket and cached locally.

**Why h9.** Nix gets per-program environments with symlink farms, store
paths and wrappers, because Linux has one global view of the filesystem.
Plan 9's union `bind -a` gives that per process natively, and h9 brings it
to macOS, Linux, Windows and the browser. Two tools that need conflicting
versions just get different namespaces, and nothing is written to the host,
so there's nothing to uninstall.

**Sketch.**

- A registry is a 9P server over `wss://` with the tree
  `/pkg/<name>/<version>/{bin,lib,man}`, content-addressed underneath so
  caches dedupe.
- A lockfile is an `--ns` file: `mount -c wss://pkgs.example/9p /n/pkg`,
  then `bind -a /n/pkg/go/1.24/bin /bin`, one bind per dependency.
  `--print` shows the resolved world.
- A caching 9P proxy on the host (a small server on a unix socket) keeps
  fetched blobs on disk and serves them offline. Machines mount it instead
  of the registry.
- `h9 run tool@1.2` becomes a thin launcher: resolve, write the namespace
  file, run. With the Linux personality, the same scheme distributes Linux
  tools without containers.

**Builds on:** [websocket-9p](../design/websocket-9p.md),
[devsrv](../design/devsrv.md),
[linux-personality](../design/linux-personality.md),
[symlinks-in-root](../design/symlinks-in-root.md). Would pull forward
[recursive-unions](../design/recursive-unions.md) (merge package trees at
every depth, not only `/bin`), [mount-index](../design/mount-index.md)
(fast lazy fetch) and [host-srv](../design/host-srv.md) (post the cache).

### 10. Executable archives

A preservation format for software and computational results: a program,
its namespace file and a content-addressed tree, sealed together. Opening
the archive runs the program as it ran when it was archived, on whatever
host exists then, on a hypervisor, on the emulator, or in a browser.

**Why h9.** Preservation today means archiving VM or container images,
which depend on a kernel, a CPU feature set and a runtime that all drift.
A 9front program's dependency surface is tiny and frozen: the a.out format
and about 40 syscalls, with no guest kernel. An emulator written in Zig
means the archive outlives any hypervisor API, and the namespace file
states the program's entire world in a few lines anyone can read.

**Sketch.**

- An archive is one file: a manifest (the `--print` plan, the
  architecture, an h9 ABI version), the namespace file, and a
  content-addressed tree that any 9P server reading the format can serve.
- `h9 open paper.h9a` mounts it as a read-only root with an overlay for
  scratch, and runs the entry point.
- Journals, courts and regulators get "rerun this analysis" as a button,
  and the browser host makes that a link rather than an install.
- Fixity is built in: the tree's root hash is the archive's identity.

**Builds on:** [ninep-roots](../design/ninep-roots.md),
[i386](../design/i386.md), [browser-host](../design/browser-host.md),
[builtin-root](../design/builtin-root.md). Would pull forward
[hcpu](../design/hcpu.md), the dependency-free emulator.

## Personal and distributed computing

### 11. A portable personal namespace

Your computing environment as a namespace file plus a few `wss://`
endpoints. It brings up the same desktop (rio, acme, the plumber, your mail
and issues as files) on any Mac, Linux box, Windows machine or browser tab.
Services are file servers you or others run, and the client is just h9.

**Why h9.** This is Plan 9's promise that a terminal is only a view onto
your namespace, which never left Plan 9 because you needed a Plan 9
terminal. h9 makes the terminal one binary on mainstream systems: `--gfx`
gives rio and acme a host window, WebSocket roots cross corporate proxies,
and the browser host makes it zero-install.

**Sketch.**

- A home service: one 9P server over `wss://` holding `/usr/you`, plus
  adapters that present outside services as trees: `/n/mail`, `/n/gh`,
  `/n/cal`, `/n/chat`, `/n/llm`.
- `profile.ns` mounts them and binds your `bin`. `h9 --gfx --ns profile.ns
  rio` brings the desktop up anywhere.
- The plumber routes between them: plumb an issue URL and acme opens its
  body; plumb an email address and it opens a draft.
- The adapters are just 9P servers, so the same trees serve agents
  ([idea 1](#1-agent-workspaces-where-credentials-are-file-servers)), and
  people and agents share one interface to the world.

**Builds on:** [websocket-9p](../design/websocket-9p.md),
[devsrv](../design/devsrv.md), [gfx](../design/gfx.md),
[browser-host](../design/browser-host.md),
[browser-gfx](../design/browser-gfx.md). Would pull forward
[credential-helpers](../design/credential-helpers.md) and
[root-auth](../design/root-auth.md).

### 12. Borrow compute, keep your files

Plan 9's `cpu`, rebuilt for a mix of machines. A job runs on a big remote
box, a teammate's idle Mac or a browser tab, while it sees *your* files,
environment and devices. Nothing is synced or checked out on the remote
side.

**Why h9.** Remote development today means copying the repository to the
remote (Codespaces, devcontainers, rsync). With `--serve`, an h9 on your
laptop exports its namespace over a WebSocket, and a worker h9 attaches it
as `--root` and runs there. Reads stream on demand, writes come back, and
the worker never gets more than the namespace you chose to export. Both
ends are the same binary on any OS, and Linux hosts can mount the export
too, because listeners also speak 9P2000.L.

**Sketch.**

- On the laptop: `h9 --serve ws://127.0.0.1:9564/9p --serve-token @tok
  --serve-root /mnt/term/cwd`, behind a tunnel or relay.
- A scheduler matches jobs to workers: a Linux box with KVM, a GPU host, a
  browser tab. Workers run `h9 --root wss://relay/you/9p --write=ephemeral
  mk test`.
- Write-back is a policy: none (results only), reviewed through the
  overlay, or live.
- It works in reverse too: a browser tab mounts a server's dataset and runs
  the visualizer locally, so the bulk data never ships.

**Builds on:** [serve](../design/serve.md),
[websocket-9p](../design/websocket-9p.md), [kvm](../design/kvm.md),
[browser-host](../design/browser-host.md), [dotl](../design/dotl.md).
Would pull forward [mount-index](../design/mount-index.md) to make remote
walks cheap.

### 13. Browser workspaces with no backend

Runnable documents, courses and bug reports whose server only serves
files. The page starts h9 in a Worker, mounts the content over `wss://` or
from its own assets, and runs real tools on the reader's side: a compiler
course where `mk` actually runs, a bug report that reproduces when opened,
a paper whose figures rebuild in the reader's tab.

**Why h9.** Linux-in-the-browser projects boot a whole kernel from a disk
image. h9 in the browser boots no guest kernel: drawterm's kernel runs as
wasm and the CPU runs only user code, so a page starts in about the time it
takes to fetch the binaries it uses. The same namespace file runs natively
on the author's Mac and in the reader's browser, so "works on my machine"
and "works in the page" are one claim.

**Sketch.**

- A static host serves the h9 wasm bundle, a 386 root as a lazily fetched
  9P tree, and a tree per document.
- A document is an `--ns` file plus its content. Edits live in `#O` and can
  be saved to the browser's storage or published as a fork.
- Two tabs that mount the same session server share `/n/session`, with
  ramfs and the plumber, so pair programming in acme needs no shared VM.
- Grading and CI run the same bundle natively
  ([idea 5](#5-builds-keyed-by-what-they-read)), so the browser's result
  and the server's can't drift.

**Builds on:** [browser-host](../design/browser-host.md),
[browser-gfx](../design/browser-gfx.md), [i386](../design/i386.md),
[websocket-9p](../design/websocket-9p.md), [overlay](../design/overlay.md).
Would pull forward [hcpu](../design/hcpu.md) for faster guest code in the
page.

## Extending applications

### 14. A plugin runtime where the app is a file tree

An extension system any application can embed. Plugins are native
binaries in any language that targets 9front or Linux, and the app
presents its object model as a 9P tree, the way acme presents windows as
`/mnt/acme/N/{body,tag,ctl,event}`. An editor, a database, a game server or
a music app gets acme-style scriptability with hypervisor isolation.

**Why h9.** Apps choose today between in-process plugins (fast, unsafe, one
language), embedded interpreters (Lua, JavaScript) or wasm (safe, but every
host API needs bindings). A file tree is an API in no particular language
and needs no bindings: `cat`, `rc` and `awk` already speak it. h9 is a Zig
library, so the app links it, serves its tree from an in-process 9P server,
and runs each plugin in its own machine with `--net=disable` and a memory
cap. A plugin that crashes, or misbehaves on purpose, can only misuse the
files it was given.

**Sketch.**

- The app runs a 9P server for its model: `/app/docs/N/{text,selection,ctl,events}`,
  `/app/ui/menu/new`, `/app/log`. Blocking reads on `events` are the
  subscription mechanism.
- A plugin's manifest is a namespace file that says which subtrees it sees
  and whether it can write. The app shows that as its permission prompt.
- Plugins run in pooled machines, with stdio going to the app's log through
  `Machine.Options.stdio`.
- Users can also script the app from `rc`, and the same tree, exported with
  `--serve`, is a remote-control API for free.

**Builds on:** [embedding](embedding.md), [ninep-roots](../design/ninep-roots.md),
[devsrv](../design/devsrv.md),
[linux-personality](../design/linux-personality.md),
[serve](../design/serve.md). Would pull forward
[host-srv](../design/host-srv.md), whose open-connection variant hands the
app's server to the machine without a socket.

## Where to start

Agent workspaces, read-keyed builds and fan-out share most of their parts
(a daemon that embeds h9, a broker or content-addressed 9P server, and a
way to harvest overlays), so building one makes the others cheaper.
[host-srv](../design/host-srv.md) and
[overlay-export](../design/overlay-export.md) are the two open proposals
that would help the most ideas.

| Idea | Prototype today? | Smallest useful demo | Open proposals it would pull forward |
| --- | --- | --- | --- |
| 1. Agent workspaces | Yes | A Go 9P broker that serves `/n/gh` with a token it holds; the agent runs with `--write=ephemeral` and `--net-allow` for the broker only; the overlay becomes a patch | host-srv, overlay-export, credential-helpers, child-machines |
| 2. Compute-to-data | Partly | A `--profile=tight` job whose `/out` server enforces a row threshold | host-srv, root-auth, host-sandbox |
| 3. Namespaces instead of a VPN | Yes | A role namespace with two `wss://` adapters (logs, read-only SQL) under `--net=disable` | credential-helpers, root-auth |
| 4. Dependency firewall | Yes | A decoy-home manifest for one npm package's install step | cow-fork |
| 5. Read-keyed builds | Yes | A logging 9P root that records the read set of `mk` and skips a rerun when nothing in it changed | overlay-export, mount-index |
| 6. Speculative fan-out | Yes | Eight candidate patches against one tree, keeping the one whose `mk test` passes fastest | overlay-export, child-machines |
| 7. Function platform | Yes | A Go handler that reads `/req` and writes `/resp`, one machine per request | host-srv |
| 8. Flight recorder | Yes, on the emulator | Record and replay a single-process program with `--cpus 1` | a new proposal |
| 9. No-install packages | Yes | A `wss://` registry and a lockfile `--ns` that gives two programs two versions of one tool | recursive-unions, mount-index, host-srv |
| 10. Executable archives | Yes | Pack a Go program, its namespace file and a tree; reopen it on the emulator on another OS | hcpu |
| 11. Portable namespace | Yes | rio and acme over a home server on `wss://`, with one namespace file on a Mac and on Linux | credential-helpers, root-auth |
| 12. Borrow compute | Yes | The laptop serves its cwd; a Linux worker runs `mk test` against it | mount-index |
| 13. Browser workspaces | Yes | One page that runs `mk` on a C file from a static 9P tree | hcpu |
| 14. Plugin runtime | Yes | A small Zig app serving `/app/docs/N/text` that an `rc` plugin uppercases | host-srv |
