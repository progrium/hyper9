---
slug: baseline-1
title: Baseline 1 (h9 at the end of epoch 0)
status: implemented
created: 2026-11-21
authors: [progrium]
depends: [renames, cow-fork, retire-unicorn]
areas: [process]
branch: [main]
---

# Proposal: Baseline 1

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

The second baseline, which closes epoch 0 and opens epoch 1 ([epochs](epoch-0/epochs.md)). It records where h9 stood when it was cut: the commit, what h9 had become, each of epoch 0's proposals with a line on what it decided, and the open proposals carried into epoch 1. It also restates what h9 is, in SPEC.md's title and overview, since "Plan 9 executables on host hypervisors" no longer describes it. It's cut after the work that was mostly built in epoch 0 has landed and the parts have their new names, so that everything in epoch 1 is written against one vocabulary and one description. Until it's cut this file is a draft that says what the baseline will hold, and the tables are filled in by the PR that cuts it.

## Background

[baseline](epoch-0/baseline.md) recorded the work before proposals, milestones M0 to M4. Epoch 0 is everything since: about 60 proposals, which took h9 from a runner for 9front binaries on three hypervisors to a kernel that also runs Linux binaries, has its own CPUs for three architectures, runs in a browser, serves its namespace over 9P, and sandboxes by namespace.

A reader today has to go through those proposals in order to learn why h9 is the way it is, and the first line of SPEC.md still describes the project of M0. Epoch 1's proposals ([kernel-port](kernel-port.md), [scheduler](scheduler.md), [memory-model](memory-model.md), [file-interface](file-interface.md), [host-handles](host-handles.md), and [plan-format](plan-format.md)) change h9's structure, and each needs to say what it's changing from.

## Proposal

### What depends on what

The baseline is cut once these are implemented:

- **[renames](epoch-0/renames.md),** so the baseline, the spec, and epoch 1 say ABI, engine, `sud`, and `hcpu`. It depends on [hcpu](epoch-0/hcpu.md).
- **[cow-fork](epoch-0/cow-fork.md),** which is partly built and which [memory-model](memory-model.md) builds on.
- **[retire-unicorn](epoch-0/retire-unicorn.md),** so the baseline describes one emulator.

Other open proposals don't hold it up. They're carried over, and listed as such.

### What the baseline holds

When it's cut, this file gains:

- **The commit** on main that it describes, and the 9front release and drawterm revision pinned then.
- **What h9 is,** in a few paragraphs: the statement that replaces SPEC.md's title and opening.
- **Epoch 0's proposals,** as a table of slug, status, and one line on what each decided or why it was declined, in the order they were written. It's the index to `design/epoch-0/`.
- **Carried over:** the proposals still open, with their status.
- **Epoch 1's direction:** the proposals above, and how they depend on each other.
- **Settled questions** from epoch 0 that aren't in any one proposal, as [baseline](epoch-0/baseline.md) has for the milestones.

### SPEC.md

SPEC.md's title becomes "Design: h9, a namespace kernel for Plan 9 and Linux executables", and its Overview's first paragraph, Goals, and Non-goals are rewritten to match what's built: a kernel with per-process namespaces, two ABIs, and engines that are hypervisors, stub processes, and h9's own CPUs. The decisions table is brought up to date. Nothing is described that isn't built.

### Cutting it

The PR that cuts the baseline is the last of epoch 0. Before it, `zig build design -- archive` is run in its own PR while the current epoch is still 0, so every closed proposal of epoch 0 is in `design/epoch-0/`. The cutting PR then fills in this file, updates SPEC.md, and sets `status: implemented`, which opens epoch 1: from then on `archive` moves closed proposals into `design/epoch-1/`. This file stays at the top of `design/` through epoch 1 and is archived with it.

## The baseline

### The commit

Epoch 0 ends at [99edb60](https://github.com/progrium/hyper9/commit/99edb600acfa8e65782f6455233c5c3fcc1274e7) on main, Nov 25, 2026, the last commit before the PR that cut this baseline. It pins 9front release 11952, "THIS WAS SUPPOSED TO BE FUN" (August 2026, source revision `602faae9a52f342a40b086d10b23c71c82dd52d7`), and drawterm at `be39bbaa88fda83bf75be642d093b20956297c8c`, both in [scripts/pins.sh](../scripts/pins.sh). It builds with Zig 0.17.1.

### What h9 is

h9 is a namespace kernel for Plan 9 and Linux executables. It's a Zig library and a thin CLI that run 9front and Linux programs directly on macOS, Linux, and Windows, and in a browser, with no VM image, no boot, and no guest kernel. Each run is one machine: a kernel in the host process, built on drawterm's Plan 9 kernel, that holds a whole process tree and serves every system call its processes make.

The kernel is built around namespaces. Every process has its own, made from a plan that the flags compile to: host directories, 9P servers (over TCP, a unix socket, a WebSocket, or, on the web host, a `MessagePort`), static trees over HTTP, archives, and a root built into the binary, stacked and bound as on 9front. Writes to the root land in a copy-on-write overlay that's gone when the run ends, while the cwd and paths made writable write to the host. The sandbox is the namespace plus a policy enforced in the kernel, so it's the same on every host and engine: a guest reaches what's bound and nothing else, and the network is outbound only by default. A machine can serve its namespace over 9P2000 or 9P2000.L, and the namespace kernel is a build with namespaces and nothing for running programs, for the web host and as a native library.

Programs reach the kernel through one of two ABIs, picked at exec by the binary's format: 9front's, for a.out binaries, and Linux's, for ELF binaries, with threads, sockets and readiness, ptys, FIFOs, and copy-on-write fork. Processes of both kinds are the same kernel processes, with the same namespaces, fds, pipes, and notes, so they can pipe to and exec each other.

Guest code runs on an engine. The hypervisor engines are Hypervisor.framework on macOS, KVM on Linux, and WHP on Windows. sud runs guest code on the host CPU, in a stub process per address space, for Linux x86\_64 hosts without KVM. hcpu is h9's own CPUs, ha64, hx64, and h86, for arm64, amd64, and 386, each with an interpreter and a JIT. It's built into every `h9`, runs every architecture on every host, and is the only engine on the web host. Everything above the engine interface is written once.

### Epoch 0's proposals

In the order they were written, as [STATUS.md](STATUS.md) lists them. Each is in [epoch-0/](epoch-0/).

| Proposal | Status | What it decided |
| --- | --- | --- |
| [proposals](epoch-0/proposals.md) | implemented | Design changes go through proposals in `design/`, ordered by their dependency graph; milestones and SPEC.md's changelog go, and SPEC.md describes only what's built. |
| [semaphores](epoch-0/semaphores.md) | implemented | `rendezvous` and the semaphore calls are served on drawterm's sleep and wakeup, which Go's runtime and every lib9p server need. |
| [segattach](epoch-0/segattach.md) | implemented | The segment calls are served for `shared` and `memory` segments, by 9front's rules; `#g` and device memory stay out. |
| [net-policy](epoch-0/net-policy.md) | implemented | The network is outbound only by default, with `--net-allow` patterns checked in devip on every connect, and link-local addresses refused. |
| [ephemeral-writes](epoch-0/ephemeral-writes.md) | implemented | `#O`, a copy-on-write overlay device in h9's kernel, enforces `--write=ephemeral` and gives every machine a private in-memory `/tmp`. |
| [go-compat](epoch-0/go-compat.md) | implemented | Go's `plan9/amd64` binaries run, with nanosecond time, `#c/pid`, a `/dev/sysstat` line per vCPU, and `_NSEC`. |
| [devsrv](epoch-0/devsrv.md) | implemented | devsrv is ported as a per-machine `/srv`, with `mount`, `unmount`, and `fauth`, so guest file servers post and mount. |
| [self-host](epoch-0/self-host.md) | implemented | Rebuilding `/sys/src` inside h9 is tested and documented, and acid can debug a live process. |
| [overlay](epoch-0/overlay.md) | implemented | `--write=overlay` is the default: the root, of any kind, sits under `#O`, and the host root tree is never written. |
| [ninep-roots](epoch-0/ninep-roots.md) | implemented | `--root` takes a 9P server by dial string or unix socket, mounted through devmnt as `/`. |
| [image-roots](epoch-0/image-roots.md) | declined | Disk-image roots weren't needed: host trees, 9P servers, and overlays covered every root. |
| [gfx](epoch-0/gfx.md) | implemented | `--gfx` gives a machine one host window from drawterm's GUI backends, and the draw devices are masked without it. |
| [kvm](epoch-0/kvm.md) | implemented | A KVM engine on arm64 and x86\_64, sharing HVF's arm64 shim and adding the amd64 shim WHP shares. |
| [whp](epoch-0/whp.md) | implemented | A WHP engine on Windows x86\_64, loading `WinHvPlatform.dll` at run time and falling back to the emulator. |
| [zig-interpreter](epoch-0/zig-interpreter.md) | superseded | A Zig interpreter to replace Unicorn; superseded by [hcpu](epoch-0/hcpu.md). |
| [baseline](epoch-0/baseline.md) | implemented | The record of milestones M0 to M4, before proposals, which opened epoch 0. |
| [hide-host-paths](epoch-0/hide-host-paths.md) | superseded | Hiding host paths in `/proc/n/ns`; superseded by [host-handles](host-handles.md). |
| [i386](epoch-0/i386.md) | implemented | 9front's 386 binaries run as a third architecture, on the emulator only. |
| [browser-host](epoch-0/browser-host.md) | implemented | h9 builds for wasm32 and runs in a Web Worker, its kernel processes coroutines on JSPI, and the same build runs under Node for the tests. |
| [linux-personality](epoch-0/linux-personality.md) | implemented | Linux ELF binaries run beside 9front ones, picked at exec by format, through a second syscall table on the same kernel and namespace. |
| [websocket-9p](epoch-0/websocket-9p.md) | implemented | 9P servers can be reached over WebSockets, as roots, in namespace files, and from the guest through `/net/ws`. |
| [dotl](epoch-0/dotl.md) | implemented | One translator between 9P2000 and 9P2000.L, in both directions, with ZeroFS's `9P2000.L.Z` for reconnects, carried in by `#ℓ`. |
| [exit-status](epoch-0/exit-status.md) | implemented | A process killed by a note exits with the status a host shell expects: 128+N, 139 for a fault, and 124 for `--timeout`. |
| [symlinks-in-root](epoch-0/symlinks-in-root.md) | implemented | A bound host tree can be contained, with its symlinks resolved inside it, as `RESOLVE_IN_ROOT` does. |
| [linux-threads](epoch-0/linux-threads.md) | implemented | Linux threads, futexes, and per-thread signals, running on several vCPUs at once over one address space. |
| [linux-net](epoch-0/linux-net.md) | implemented | Linux sockets are served by `/net` under the same policy, with `poll`, `epoll`, and `eventfd` from a readiness leaf in the kernel. |
| [host-binfmt](epoch-0/host-binfmt.md) | declined | Registering h9 with `binfmt_misc` is host integration h9 doesn't take on. |
| [guest-tools](epoch-0/guest-tools.md) | implemented | h9's own scripts are built in and served by `#H`, bound after `/bin`. |
| [serve](epoch-0/serve.md) | implemented | `--serve` makes a machine a 9P server on a unix socket, TCP, or a WebSocket, with `/net` left out unless asked for. |
| [multicall](epoch-0/multicall.md) | implemented | 9front's commands build, unmodified, into one multi-call `9box`, the core of a slim root. |
| [builtin-root](epoch-0/builtin-root.md) | implemented | A slim root is built into `h9` and used when no root is found, so `h9` works with nothing else installed. |
| [host-scripts](epoch-0/host-scripts.md) | implemented | A host file starting with `#!` runs as a guest script, its interpreter found in the guest namespace. |
| [host-srv](epoch-0/host-srv.md) | superseded | Posting host connections in `/srv`; superseded by [mounts](epoch-0/mounts.md). |
| [root-auth](epoch-0/root-auth.md) | declined | Authentication for roots goes through HTTP and WebSocket, not `p9any` on 9P roots. |
| [default-command](epoch-0/default-command.md) | implemented | `h9 --rc` with no command runs a login rc, so a root sets its default command in `/rc/lib/rcmain.local`. |
| [credential-helpers](epoch-0/credential-helpers.md) | implemented | A host command chosen by URL pattern supplies the headers for each WebSocket handshake, which the guest never sees. |
| [browser-gfx](epoch-0/browser-gfx.md) | implemented | The web host gets the gfx devices on a page's canvas, and a snarf buffer only a paste fills. |
| [overlay-export](epoch-0/overlay-export.md) | superseded | Exporting a run's overlay as an OCI layer; superseded by [upper-layers](epoch-0/upper-layers.md). |
| [schemeless-roots](epoch-0/schemeless-roots.md) | implemented | A root shaped like `host[:port][/path]` that isn't an existing path is a WebSocket URL. |
| [login-shell](epoch-0/login-shell.md) | declined | Making rc the shell a terminal opens is host integration out of scope; `h9 --rc` covers it. |
| [native-backend](epoch-0/native-backend.md) | implemented | An engine, now sud, that runs guest code on the host CPU through Syscall User Dispatch, for Linux without KVM. |
| [recursive-unions](epoch-0/recursive-unions.md) | superseded | Unions merged at every depth, and `--layer`; superseded by [mounts](epoch-0/mounts.md). |
| [linux-i386](epoch-0/linux-i386.md) | implemented | 32-bit x86 Linux programs run, on the emulator and on the web host. |
| [tilde-roots](epoch-0/tilde-roots.md) | declined | A search path of root prefixes wasn't needed; full names and schemeless roots were enough. |
| [cow-fork](epoch-0/cow-fork.md) | implemented | A Linux `fork` shares pages copy-on-write, and private file pages are filled when first touched. |
| [mount-index](epoch-0/mount-index.md) | implemented | A 9P tree can carry a dotfs index, cached on the host, so walks, stats, and directory reads don't reach the server. |
| [hcpu](epoch-0/hcpu.md) | implemented | h9's own CPUs, h86, ha64, and hx64, each an interpreter and a JIT over a shared IR, replace Unicorn and v86. |
| [proposal-flow](epoch-0/proposal-flow.md) | implemented | Work can start before its proposal: branches, optional `proposed` and `accepted` states, Done criteria, slugs everywhere, and easier signing. |
| [kernel-serve](epoch-0/kernel-serve.md) | implemented | The kernel serves 9P2000 itself, in place of an `exportfs` guest process per connection. |
| [namespace-kernel](epoch-0/namespace-kernel.md) | implemented | A build of the kernel with only namespaces, made and composed through `#N`, as `h9ns.wasm` and a native library. |
| [port-streams](epoch-0/port-streams.md) | implemented | On the web host, a `MessagePort` carries a 9P connection the way a WebSocket does. |
| [linux-fifo](epoch-0/linux-fifo.md) | implemented | Linux FIFOs stay in the file system and join a machine-wide pipe on open. |
| [linux-pty](epoch-0/linux-pty.md) | implemented | Linux pseudoterminals, raw first and then with a line discipline. |
| [mounts](epoch-0/mounts.md) | implemented | One family of mount flags, each a line of the plan, with stacks merged at every depth and `/` built as on 9front. |
| [epochs](epoch-0/epochs.md) | implemented | Closed proposals are archived in `design/epoch-N/`, and a baseline opens each epoch. |
| [linux-symlinks](epoch-0/linux-symlinks.md) | implemented | Linux symlinks are followed in the kernel's walk from the process's own root. |
| [renames](epoch-0/renames.md) | implemented | Personalities became ABIs, `vmm` and backends became engines, native became sud, and the emulator became hcpu. |
| [retire-unicorn](epoch-0/retire-unicorn.md) | implemented | Unicorn is no longer an engine, only `zig build lockstep`'s oracle, and never in anything h9 ships. |
| [spec-split](epoch-0/spec-split.md) | implemented | SPEC.md is the overview, and each part of h9 is described in a file under `spec/`. |
| [fd-mounts](epoch-0/fd-mounts.md) | implemented | An embedder can hand h9 a host descriptor, or a pipe pair, that it already serves 9P on. |
| [upper-layers](epoch-0/upper-layers.md) | implemented | `up` makes a host tree the writable layer of a stack, an unpacked OCI layer with whiteouts. |
| [headless-screen](epoch-0/headless-screen.md) | implemented | `--gfx=headless` gives a screen in memory, which `/dev/screen`, `/dev/mousein`, and `/dev/kbdin` drive. |
| [linux-chroot](epoch-0/linux-chroot.md) | implemented | A Linux `chroot` narrows a process's root, never past the machine's Linux view. |

### Carried over

The proposals still open when epoch 0 closed, in the order they were written. They're at the top of `design/`, and STATUS.md has their current state.

| Proposal | Status | Title |
| --- | --- | --- |
| [host-sandbox](host-sandbox.md) | draft | Host self-sandboxing |
| [audio](audio.md) | draft | Audio (`--audio`) |
| [host-cmd](host-cmd.md) | draft | Rethinking host commands |
| [child-machines](child-machines.md) | proposed | Child machines |
| [wine-draw](wine-draw.md) | proposed | Wine windows through draw |
| [file-interface](file-interface.md) | draft | A wider file interface inside the kernel, with 9P2000 as a view |
| [host-handles](host-handles.md) | draft | Host access through handles |
| [kernel-port](kernel-port.md) | draft | Port the kernel core to Zig, as an instance |
| [memory-model](memory-model.md) | draft | One memory model under both ABIs |
| [plan-format](plan-format.md) | draft | The plan as a file, and the one way in |
| [scheduler](scheduler.md) | draft | A scheduler, with processes on per-core executors |
| [file-watch](file-watch.md) | draft | Watching files for changes, on the host and in the guest |
| [virtual-loopback](virtual-loopback.md) | draft | A loopback network per machine |
| [linux-dns](linux-dns.md) | draft | Name patterns for a Linux guest's DNS |

### Epoch 1's direction

Epoch 1 changes h9's structure, starting from the kernel:

- **[kernel-port](kernel-port.md)** ports the namespace core from drawterm's C to Zig, and makes a kernel a value a machine owns. It depends on this baseline, [namespace-kernel](epoch-0/namespace-kernel.md), and [kernel-serve](epoch-0/kernel-serve.md).
- **[scheduler](scheduler.md)** runs processes as kernel objects on per-core executors, in place of a host thread per process. It depends on kernel-port.
- **[file-interface](file-interface.md)** widens the device interface past 9P2000's operations, for what Linux programs need from a file. It depends on kernel-port.
- **[host-handles](host-handles.md)** gives the kernel a table of host handles in place of calling the host directly, so the policy is which handles exist. It depends on kernel-port, and [host-sandbox](host-sandbox.md) depends on it.
- **[memory-model](memory-model.md)** moves 9front processes onto the Linux ABI's memory model, so both ABIs share copy-on-write and demand-loaded pages. It depends on this baseline and [cow-fork](epoch-0/cow-fork.md).
- **[plan-format](plan-format.md)** makes the plan a documented text format, and the one input every way of starting a machine takes. It depends on this baseline, [mounts](epoch-0/mounts.md), and [child-machines](child-machines.md).

So kernel-port comes first, and scheduler, file-interface, and host-handles follow it, while memory-model and plan-format can go alongside it.

### Settled questions

Questions settled in epoch 0 outside any one proposal:

- [x] Zig: h9 moved to Zig 0.17.1 ([#293](https://github.com/progrium/hyper9/pull/293)). A version change is its own PR, made after building and testing on every host.
- [x] Licensing: h9 is MIT, emulator included. GPL and AGPL code (Unicorn, diod, and ZeroFS) is used only by dev and CI tools, and is never linked into anything h9 ships ([retire-unicorn](epoch-0/retire-unicorn.md), [dotl](epoch-0/dotl.md)).
- [x] Pins: 9front stayed at release 11952 for all of epoch 0. drawterm is a squashed subtree in `third_party/drawterm`, updated only with `scripts/vendor-drawterm.sh`.
- [x] Host integration: h9 runs as a program and doesn't integrate further with the host. `binfmt_misc` registration and use as a login shell were both declined for that reason ([host-binfmt](epoch-0/host-binfmt.md), [login-shell](epoch-0/login-shell.md)).
- [x] Authentication: roots authenticate over HTTP and WebSocket, through credential helpers, not with 9P's own auth ([credential-helpers](epoch-0/credential-helpers.md), [root-auth](epoch-0/root-auth.md)).
- [x] Naming roots: a root is named in full, shortened only by schemeless URLs, with no search path ([schemeless-roots](epoch-0/schemeless-roots.md), [tilde-roots](epoch-0/tilde-roots.md)).
- [x] `--strict` is gone, since every capability is enforced on every build, and `--dump-on-fault` is part of `--trace` ([#185](https://github.com/progrium/hyper9/pull/185)).
- [x] Cross-architecture runs: hcpu runs any of the three architectures on any host, so running another architecture's binaries is something h9 does for users, not only for testing, and SPEC.md no longer lists it as a non-goal.
- [x] The open issues of this proposal: the title is "a namespace kernel for Plan 9 and Linux executables"; [retire-unicorn](epoch-0/retire-unicorn.md) did hold the baseline up, and was done in time; and the table of epoch 0's proposals is written by hand, since a line on what each decided isn't in its frontmatter.

## Rationale

**Why a baseline at all, and not just the next proposal.** Sixty proposals is past what anyone reads in order, and the archive made room at the top of `design/` without making the history easier to enter. A baseline is the one page to read first.

**Why wait for renames, cow-fork, and retire-unicorn.** A baseline written before the renames would describe h9 in words the next proposal abandons. cow-fork is half merged, and a baseline that says "partly" is a poor foundation for [memory-model](memory-model.md). Unicorn is the difference between "the emulator" being one thing and two.

**Why not wait for more.** [namespace-kernel](epoch-0/namespace-kernel.md), [kernel-serve](epoch-0/kernel-serve.md), [mounts](epoch-0/mounts.md), and [child-machines](child-machines.md) are designs that epoch 1 builds on, and none is far enough along to hold a baseline for. Waiting for them would put the baseline after the work it's meant to orient.

**Why retitle SPEC.md here.** The title is the claim about what h9 is, and the baseline is where that claim is restated on purpose. [renames](epoch-0/renames.md) leaves it alone for that reason.

## Compatibility

None for users: no code changes. `archive` files closed proposals under `design/epoch-1/` once this is implemented.

## Security

None. It's a record.

## Done criteria

- [x] [renames](epoch-0/renames.md), [cow-fork](epoch-0/cow-fork.md), and [retire-unicorn](epoch-0/retire-unicorn.md) are implemented.
- [x] `zig build design -- archive --dry-run` reports nothing to archive, with the current epoch still 0.
- [x] This file has the commit, the statement of what h9 is, the table of epoch 0's proposals with every proposal in `design/epoch-0/` on a line, and the carried-over list.
- [x] SPEC.md has the new title and overview, its decisions table matches what's built, and it's signed by the person who reviewed it as a whole.
- [x] `zig build design -- check` passes, and `zig build design -- status` shows an Epoch 0 table and an empty Epoch 1.

## Implementation

1. Wait for the three dependencies.
2. Run `archive` in a PR of its own.
3. Write the table of epoch 0's proposals, from each one's Abstract and Declined or Updates sections.
4. Write what h9 is, here and in SPEC.md.
5. Set `status: implemented` and `branch: [main]`.

## Open issues

- The new title. "A namespace kernel for Plan 9 and Linux executables" is a proposal, and it's the sentence people will repeat.
- Whether [retire-unicorn](epoch-0/retire-unicorn.md) should hold the baseline up, or be carried over if it isn't done when renames is.
- Whether the table of epoch 0's proposals is written by hand or generated by the tool from each proposal's frontmatter and Abstract.
