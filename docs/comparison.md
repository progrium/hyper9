# How h9 compares

> **Work in progress.** h9 is under active development and hasn't had a
> security audit. Most of what this guide describes is built: 9front and
> Linux programs, the HVF and KVM backends, the emulator, and the browser
> host. The [Linux personality](../design/0018-linux-personality.md) and its
> [threads](../design/0049-linux-threads.md) and
> [sockets](../design/0050-linux-net.md) are built but their proposals are
> still drafts while gaps close. Parts that are still drafts or not built
> are marked *(planned)*, chief among them the
> [WHP backend](../design/0017-whp.md) for Windows. The
> [proposal status](../design/STATUS.md) is the current state.
>
> This is a short map from things you may already know to h9. The
> [manual](../MANUAL.md)'s first chapter has a smaller version for other ways
> to run Plan 9; this one goes wider. For how h9 works, see
> [SPEC.md](../SPEC.md).

## h9 in one paragraph

h9 runs programs as host commands, each invocation in its own small machine.
Every guest process runs in user mode on its own vCPU from the host
hypervisor, and its syscalls exit to a kernel running inside the h9 process:
drawterm's Plan 9 kernel. There's no VM image, no boot, and no guest kernel.
The programs are native 9front binaries and Linux ELF binaries, side by side
in one machine: a Linux process's syscalls go through a second syscall table
onto the same kernel, so the two kinds share one mount table, file
descriptors, pipes, and sandbox policy, and pipe to and exec each other. A
Linux process sees a Linux root tree such as Alpine's minirootfs, with the
9front tree at `/9`. What the guest can reach of the host is a namespace h9
builds from a root (a host directory, a 9P server, or the small root built
into the h9 binary), the host cwd, and whatever the sandbox flags bind;
nothing else.

So h9 sits in an unusual spot: it uses hardware virtualization like a
microVM, serves syscalls in user space like gVisor, starts like a native
process, and its kernel is Plan 9's, which makes the namespace, 9P, and
`/srv` the way everything is put together.

## At a glance

| | What runs | Isolation | Kernel serving syscalls | Starts in | Image/boot |
| --- | --- | --- | --- | --- | --- |
| **h9** | Unmodified 9front and Linux binaries | Hypervisor (user mode on a vCPU) plus a namespace allowlist | drawterm's Plan 9 kernel in the h9 process, with a Linux syscall table over it | Milliseconds | None; a file tree, a 9P server, or the built-in root |
| 9front in QEMU | The whole 9front system | Full VM | The real 9front kernel, in the guest | Seconds (boot) | Disk image, boot, drivers |
| 9vx | Plan 9 binaries (386) | vx32 software sandbox | A Plan 9 kernel in the 9vx process | Fast | None |
| plan9port | Plan 9 tools recompiled for Unix | None (ordinary Unix processes) | The host kernel | Native | None |
| Docker / OCI | Linux binaries | Linux namespaces, cgroups, seccomp | The shared host Linux kernel (a Linux VM on macOS and Windows) | ~100 ms+ | Layered image |
| gVisor | Linux binaries | ptrace, systrap, or KVM platform | The Sentry (Linux in Go), in user space | ~100 ms+ | OCI image |
| Docker Sandboxes | A coding agent in a Linux VM, with its own Docker daemon | Full VM per sandbox (HVF, WHP, or KVM), plus a host proxy for network and credentials | A guest Linux kernel | Fast boot, then persistent | Agent template image |
| Firecracker | A Linux VM | Full VM (KVM) | A guest Linux kernel | ~125 ms boot | Kernel plus rootfs image |
| WSL 1 / WSL 2 | Linux binaries on Windows | Process / full VM | NT translating Linux calls / a real Linux kernel | Fast / seconds | Distro rootfs |
| Wine | Windows binaries on Unix | None | The host kernel, behind a Win32 reimplementation | Native | A prefix directory |
| qemu-user | Foreign-arch Linux binaries | None | The host kernel, with syscalls translated | Fast | None |
| WASI runtimes | wasm modules | The wasm sandbox | The runtime's WASI host calls | Very fast | None |
| v86 | An x86 PC in the browser | Emulation | Whatever OS you boot in it | Seconds (boot) | Disk or CD image |

## Running Plan 9

**9front in QEMU, or on hardware.** That's the real system: the 9front kernel,
its drivers, a disk, a boot. h9 deliberately isn't (running the 9front kernel
is a [non-goal](../SPEC.md#overview)). It runs one program, or one process
tree, against a namespace it builds, and exits with it. You get a real 9front
userland as host commands (`git log | h9 sort | h9 uniq -c`), rio and acme in
a host window with `--gfx`, and the compilers and `mk` rebuilding 9front
inside it ([self-host](../design/0010-self-host.md)), but no 9front kernel
features beyond what drawterm's kernel and h9 add. h9 does use QEMU once:
`zig build mkroot` boots the pinned 9front image to extract the full root
tree. Without one, h9 falls back to a [built-in root](../design/0087-builtin-root.md)
of 42 9front commands in one multi-call binary. Using a 9front disk image
directly as the root was proposed and declined
([image-roots](../design/0014-image-roots.md)): directories, 9P servers, and
overlays have covered every root so far.

**9vx.** h9's closest ancestor: Plan 9 binaries running on a Unix host, with a
Plan 9 kernel in the host process serving their syscalls. 9vx confined guest
code with vx32's segmentation-based software sandbox, so it was 32-bit x86
only and it hasn't kept up with current hosts. h9 does the same job with the
host hypervisor, for arm64 and amd64, and on the emulator for 386.

**drawterm.** drawterm connects a Unix, Mac, or Windows machine to a remote
Plan 9 cpu server, and the programs run there. h9 vendors drawterm's kernel
and turns it around: the programs run locally, and drawterm's kernel serves
their syscalls instead of fronting a remote session.

**plan9port.** Plan 9's tools and libraries ported to Unix and recompiled
against POSIX. They're ordinary host processes in the host's single namespace,
with no per-process namespaces, no `/srv` or `bind` as Plan 9 has them, and no
isolation. h9 runs the actual 9front binaries, unmodified, with real
per-process namespaces, `/proc`, `/srv`, notes, and 9P mounts, because the
kernel serving them is a Plan 9 kernel. With the Linux personality, h9 also
covers plan9port's other use, mixing Plan 9 tools with Unix ones in one
pipeline, without porting either side.

## Containers and sandboxes

**Docker and OCI containers.** A container is a set of Linux processes on the
host kernel, fenced by namespaces, cgroups, and seccomp; on macOS and Windows
it needs a Linux VM underneath. h9 covers a lot of the same ground from a
different direction:

- **Linux userland without a Linux kernel.** `h9 --root alpine sh` runs
  Alpine's shell, and `h9 --root alpine --writable alpine apk add jq`
  installs into the tree, as uid 0 the way a rootless container does. There's
  no Linux VM on macOS: Linux syscalls are translated onto h9's kernel in the
  h9 process. SQLite, PostgreSQL, Redis, git, CPython, the Go toolchain, and
  Zig have all been run this way (see the
  [Linux personality page](../site/linux.html)).
- **Image vs root.** A container starts from a layered image. h9 starts from a
  root tree, a 9P server ([9p-roots](../design/0013-9p-roots.md)), or one
  behind a WebSocket ([websocket-9p](../design/0021-websocket-9p.md)), and
  composes layers with Plan 9 binds and a copy-on-write overlay. The overlay
  is the default ([overlay](../design/0011-overlay.md)): writes to the root
  succeed and vanish at exit. Exporting a run's changes as an OCI layer is a
  draft ([overlay-export](../design/overlay-export.md), *planned*). See
  [userland.md](userland.md) for building your own root.
- **Namespaces.** Linux bolted namespaces on; in Plan 9 every process already
  has its own, and the guest can rearrange it with `bind` and `mount` without
  privileges. h9's sandbox is that namespace: anything not bound doesn't exist,
  for 9front and Linux processes alike.
- **Policy.** h9's flags (`--readable`, `--writable`, `--read-deny`,
  `--net=outbound`, `--net-allow`, `--memory`, `--pids`, `--timeout`) are
  enforced in h9's kernel, so they're the same on every host and backend.
  Linux sockets are `/net` conversations, so the network rules apply to them
  unchanged.
- **Exit codes.** 125, 126, and 127 follow `docker run`.
- **What h9 lacks:** a registry, OCI images, a daemon, and long-running
  services managed from outside. Each invocation is its own machine and ends
  with its program. Linux coverage is a syscall table, not a Linux kernel, so
  calls h9 doesn't serve fail with `ENOSYS`, and some things, such as
  job-control stops, aren't there yet.

**gVisor.** The closest relative, doing the same job. gVisor's Sentry is a
user-space kernel that serves a Linux application's syscalls so they never
reach the host kernel, and its KVM platform runs the application on a vCPU.
h9 has the same shape: the vmm layer is the platform, and drawterm's kernel,
with the Linux syscall table translated onto it, is the Sentry. The
differences:

- h9's kernel is Plan 9's, so Linux processes share a machine with 9front
  ones and see 9P servers as ordinary mounts.
- h9 runs on macOS and Windows hosts as well as Linux, and in a browser.
- gVisor is a mature, production sandbox. h9's security has had no audit
  (see the warning in the manual's
  [Sandboxing](../MANUAL.md#23-sandboxing) chapter).

**Docker Sandboxes.** Docker's `sbx` runs AI coding agents (Claude Code,
Codex, Copilot, and others) each in its own microVM, on Docker's own VMM over
Hypervisor.framework, the Windows Hypervisor Platform, or KVM: the same three
hypervisors h9 uses. The guest is a whole Linux system with its own kernel and
a private Docker daemon, so an agent can `docker build` and `docker compose`
without reaching the host's daemon. A sandbox is persistent: `sbx run`,
`sbx stop`, and `sbx rm` manage it, and its packages, images, and files
survive restarts. The project directory is shared into the VM at the same
path with virtiofs, or mounted read-only beside a private clone, or not at
all. All outbound TCP goes through a proxy on the host that enforces a
domain policy (Open, Balanced, or Locked Down, and per-host rules) and swaps
a placeholder for the real API key, so the key never enters the VM. The
differences:

- **One machine per agent, or one per command.** A sandbox is a long-lived
  workstation for an agent. An h9 machine starts in milliseconds, runs one
  process tree, and ends with it, so it can fence a single step of a
  pipeline (`git log | h9 sort`) as easily as a shell.
- **A Linux kernel, or a syscall table.** sbx runs anything Linux runs,
  Docker included. h9's [Linux personality](../design/0018-linux-personality.md)
  runs a growing set of programs and fails the rest with `ENOSYS`, and there's
  no Docker inside h9.
- **Host files.** sbx shares the workspace whole, and can't hide a file in
  it, so `.env` is readable in every mode. h9 binds only what the flags name,
  hides paths with `--read-deny`, keeps writes in memory with
  `--write=ephemeral`, and prints the result with `--print`.
- **Network.** sbx filters by domain at an HTTP proxy and injects
  credentials. h9 filters `/net` dials by dial string with `--net-allow`, and
  resolves only names a pattern covers ([net-policy](../design/0005-net-policy.md)).
  h9 injects credentials only into WebSocket 9P handshakes, and that's a draft
  ([credential-helpers](../design/0119-credential-helpers.md), *planned*).
- **Images.** sbx starts from agent templates, with an image cache per
  sandbox. h9 starts from a root tree or a 9P server, and
  [h9reg](https://github.com/progrium/h9reg) serves OCI images as 9P roots.
- **Maturity.** sbx is a product, closed source, and needs a Docker sign-in.
  h9 is MIT licensed and unaudited, and the h9 process isn't sandboxed by the
  host yet ([host-sandbox](../design/host-sandbox.md), *planned*).

If you want to hand a repository to a coding agent today, sbx is built for
it. h9 fits when you want a policy per command, file-level denies, writes
that vanish, or the same sandbox in a browser.

## Virtual machines

**Firecracker and other microVMs.** Firecracker uses KVM to boot a minimal
Linux guest kernel fast, for serverless and multi-tenant isolation. h9 uses
the hypervisor too, KVM on Linux as well, but only to isolate memory and the
CPU: there is no guest kernel, and the guest code in kernel mode is a few
hundred lines of shim that saves registers and exits to the host. So startup
is closer to a process than to a boot, and the host sees and serves every
syscall. The trade is that h9 runs programs, not an operating system: no
guest kernel features beyond what h9 serves, and no devices. If you want
complete Linux in isolation, a microVM is the better tool; the Linux
personality proposal says so itself. h9's closest relative on this axis is
[hyper-linux](https://github.com/zw3rk/hyper-linux), which runs Linux ELF
binaries on macOS's Hypervisor.framework the same way, and whose shim and
ELF loader h9's design draws on.

**WSL.** WSL 1 translated Linux syscalls in the host OS kernel (NT), with no
VM. h9's Linux personality is the same idea, with the translation in user
space behind a hypervisor and onto a Plan 9 kernel rather than NT. WSL 2 is a
lightweight VM with a real Linux kernel, closer to Firecracker. On Windows,
h9 mostly runs on the emulator today. Its WHP backend for the Windows
Hypervisor Platform is built for x86\_64 but incomplete, and its proposal is
a draft ([whp](../design/0017-whp.md), *planned*).

## Compatibility layers

**Wine.** Wine runs Windows programs on Unix by reimplementing the Windows API
in user space; the program's code runs directly on the host CPU, as an
ordinary host process. h9 is a compatibility layer in the same sense (foreign
binaries, native code, an ABI served by someone else's kernel), for Plan 9
and Linux binaries on macOS, Linux, and Windows. But its ABI is a kernel's
syscall table rather than a library API, and h9 runs the guest in a VM so its
code can't touch the host directly. Wine is not a sandbox; h9 is meant to be
one.

**qemu-user and binfmt_misc.** qemu-user runs foreign-architecture Linux
binaries by translating instructions and passing syscalls to the host kernel.
h9-emu translates instructions with Unicorn, which is built on QEMU's CPU
core, but h9 serves the syscalls itself rather than handing them to the host.
The [host-binfmt](../design/host-binfmt.md) draft *(planned)* would register
h9 with `binfmt_misc` the way qemu-user is registered, so `./prog` runs a
9front binary on Linux without typing `h9`. It matches only 9front's a.out
magics: host Linux binaries still run natively.

## The browser and wasm

**v86.** v86 emulates a whole x86 PC in the browser, and you boot an OS on
it. h9's [browser host](../design/0012-browser-host.md) works
differently: h9 itself is compiled to wasm and runs in a Web Worker, with its
own 386 CPU (interpreted, and compiled to wasm when hot) and no PC around it. So in a browser tab, as on
every other host, 9front's 386 binaries and Alpine's 386 Linux binaries
(busybox, jq, sqlite3) run with no disk image, boot, or guest kernel. It
needs JavaScript Promise Integration, which Chrome and Edge have.

**WASI runtimes** (wasmtime, Wasmer, WasmEdge, and others). These run portable
wasm modules with capability-style access: preopened directories and granted
sockets, much like h9's namespace allowlist. The difference is the program: a
WASI program is compiled for wasm, while h9 runs existing native binaries and
gives them a whole environment (rc or a Linux shell, `/proc`, `/srv`, 9P,
signals and notes, process trees). The browser host puts h9 on the wasm side
as the host, not as the guest format.

## When h9 fits

- You want 9front's tools (rc, mk, sam, awk, the compilers) as host commands
  or in host pipelines, without running a 9front system.
- You want to run Linux tools in a sandbox on a Mac without a Linux VM, or
  mix them with 9front tools in one pipeline and one namespace.
- You want a small, scriptable sandbox with an explicit, printable policy
  (`h9 --print`) for build steps or tools. Remember it's unaudited.
- You want Plan 9's namespace model (`bind`, `mount`, `/srv`, 9P roots) as the
  way to compose what a program can see, on macOS, Linux, Windows, or in a
  browser, or [embedded](embedding.md) in a Zig program.

When it doesn't: if you need complete Linux compatibility, a long-running
managed service, hardware drivers, the 9front kernel itself, or a sandbox
that's been audited, use a container, gVisor, a microVM, or 9front in a VM.
