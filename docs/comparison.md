# How h9 compares

> **Work in progress.** h9 is under active development, and this guide
> describes it as planned, not only as built. In particular it assumes the
> [Linux personality](../design/0018-linux-personality.md) (Linux ELF binaries
> next to 9front ones, with [threads](../design/linux-threads.md) and
> [sockets](../design/linux-net.md)), the [KVM](../design/0016-kvm.md) and
> [WHP](../design/0017-whp.md) backends, and the
> [browser host](../design/0012-browser-host.md). None of those is built yet.
> Today h9 runs 9front binaries only, on Hypervisor.framework on macOS arm64
> and on the emulator (`h9-emu`) everywhere else. Planned parts are marked
> *(planned)* below; the README's [status table](../README.md#status) is the
> current state.
>
> This is a short map from things you may already know to h9. The
> [manual](../MANUAL.md)'s first chapter has a smaller version for other ways
> to run Plan 9; this one goes wider. For how h9 works, see
> [DESIGN.md](../DESIGN.md).

## h9 in one paragraph

h9 runs programs as host commands, each invocation in its own small machine.
Every guest process runs in user mode on its own vCPU from the host
hypervisor, and its syscalls exit to a kernel running inside the h9 process:
drawterm's Plan 9 kernel. There's no VM image, no boot and no guest kernel.
The programs are native 9front binaries and *(planned)* Linux ELF binaries,
side by side in one machine: a Linux process's syscalls go through a second
syscall table onto the same kernel, so the two kinds share one mount table,
file descriptors, pipes and sandbox policy, and can pipe to and exec each
other. A Linux process sees a Linux root tree such as Alpine's minirootfs,
with the 9front tree at `/9`. What the guest can reach of the host is a
namespace h9 builds from a root (a host directory or a 9P server), the host
cwd, and whatever the sandbox flags bind; nothing else.

So h9 sits in an unusual spot: it uses hardware virtualization like a
microVM, serves syscalls in user space like gVisor, starts like a native
process, and its kernel is Plan 9's, which makes the namespace, 9P and `/srv`
the way everything is put together.

## At a glance

| | What runs | Isolation | Kernel serving syscalls | Starts in | Image/boot |
| --- | --- | --- | --- | --- | --- |
| **h9** | Unmodified 9front binaries; Linux ELF *(planned)* | Hypervisor (user mode on a vCPU) plus a namespace allowlist | drawterm's Plan 9 kernel in the h9 process, with a Linux syscall table over it *(planned)* | Milliseconds | None; a file tree or 9P server is the root |
| 9front in QEMU | The whole 9front system | Full VM | The real 9front kernel, in the guest | Seconds (boot) | Disk image, boot, drivers |
| 9vx | Plan 9 binaries (386) | vx32 software sandbox | A Plan 9 kernel in the 9vx process | Fast | None |
| plan9port | Plan 9 tools recompiled for Unix | None (ordinary Unix processes) | The host kernel | Native | None |
| Docker / OCI | Linux binaries | Linux namespaces, cgroups, seccomp | The shared host Linux kernel (a Linux VM on macOS and Windows) | ~100 ms+ | Layered image |
| gVisor | Linux binaries | ptrace, systrap or KVM platform | The Sentry (Linux in Go), in user space | ~100 ms+ | OCI image |
| Firecracker | A Linux VM | Full VM (KVM) | A guest Linux kernel | ~125 ms boot | Kernel plus rootfs image |
| WSL 1 / WSL 2 | Linux binaries on Windows | Process / full VM | NT translating Linux calls / a real Linux kernel | Fast / seconds | Distro rootfs |
| Wine | Windows binaries on Unix | None | The host kernel, behind a Win32 reimplementation | Native | A prefix directory |
| qemu-user | Foreign-arch Linux binaries | None | The host kernel, with syscalls translated | Fast | None |
| WASI runtimes | wasm modules | The wasm sandbox | The runtime's WASI host calls | Very fast | None |
| v86 | An x86 PC in the browser | Emulation | Whatever OS you boot in it | Seconds (boot) | Disk or CD image |

## Running Plan 9

**9front in QEMU, or on hardware.** That's the real system: the 9front kernel,
its drivers, a disk, a boot. h9 deliberately isn't (running the 9front kernel
is a [non-goal](../DESIGN.md#overview)). It runs one program, or one process
tree, against a namespace it builds, and exits with it. You get a real 9front
userland as host commands (`git log | h9 sort | h9 uniq -c`) but no 9front
kernel features beyond what drawterm's kernel and h9 add. h9 does use QEMU
once: `scripts/mkroot.py` boots the pinned 9front image to extract the root
tree. The [image-roots](../design/0014-image-roots.md) draft would let h9 use
a 9front disk image directly as its root, by running 9front's own file server
as a guest process.

**9vx.** h9's closest ancestor: Plan 9 binaries running on a Unix host, with a
Plan 9 kernel in the host process serving their syscalls. 9vx confined guest
code with vx32's segmentation-based software sandbox, so it was 32-bit x86
only and it hasn't kept up with current hosts. h9 does the same job with the
host hypervisor, for arm64 and amd64, and on the emulator for 386.

**drawterm.** drawterm connects a Unix, Mac or Windows machine to a remote
Plan 9 cpu server, and the programs run there. h9 vendors drawterm's kernel
and turns it around: the programs run locally, and drawterm's kernel serves
their syscalls instead of fronting a remote session.

**plan9port.** Plan 9's tools and libraries ported to Unix and recompiled
against POSIX. They're ordinary host processes in the host's single namespace,
with no per-process namespaces, no `/srv` or `bind` as Plan 9 has them, and no
isolation. h9 runs the actual 9front binaries, unmodified, with real per-process
namespaces, `/proc`, `/srv`, notes and 9P mounts, because the kernel serving
them is a Plan 9 kernel. With the Linux personality *(planned)*, h9 also
covers plan9port's other use, mixing Plan 9 tools with Unix ones in one
pipeline, without porting either side.

## Containers and sandboxes

**Docker and OCI containers.** A container is a set of Linux processes on the
host kernel, fenced by namespaces, cgroups and seccomp; on macOS and Windows
it needs a Linux VM underneath. With the Linux personality *(planned)*, h9
covers a lot of the same ground from a different direction:

- **Linux userland without a Linux kernel.** `h9 --linux-root alpine sh`
  *(planned)* runs Alpine's busybox and `apk`, as uid 0 the way a rootless
  container does, but with no Linux VM on macOS or Windows: Linux syscalls are
  translated onto h9's kernel in the h9 process.
- **Image vs root.** A container starts from a layered image. h9 starts from a
  root tree, a 9P server ([9p-roots](../design/0013-9p-roots.md)), or one
  behind a WebSocket ([websocket-9p](../design/0021-websocket-9p.md)), and
  composes layers with Plan 9 binds and a copy-on-write overlay device
  (`--write=ephemeral` today; [overlay](../design/0011-overlay.md) as the
  default is accepted). See [userland.md](userland.md) for building your own.
- **Namespaces.** Linux bolted namespaces on; in Plan 9 every process already
  has its own, and the guest can rearrange it with `bind` and `mount` without
  privileges. h9's sandbox is that namespace: anything not bound doesn't exist,
  for 9front and Linux processes alike.
- **Policy.** h9's flags (`--readable`, `--writable`, `--read-deny`,
  `--net=outbound`, `--net-allow`, `--memory`, `--pids`, `--timeout`) are
  enforced in h9's kernel, so they're the same on every host and backend, and
  Linux sockets *(planned)* go through `/net`, so the network rules apply to
  them unchanged.
- **Exit codes.** 125, 126 and 127 follow `docker run`.
- **What h9 lacks:** a registry, OCI images, a daemon, and long-running
  services managed from outside. Each invocation is its own machine and ends
  with its program. Linux coverage is a syscall table, not a Linux kernel, so
  calls h9 doesn't serve return `ENOSYS`; it targets busybox, Python, compilers,
  Go and network servers first, not everything a container can run.

**gVisor.** The closest relative, and with the Linux personality the same job.
gVisor's Sentry is a user-space kernel that serves a Linux application's
syscalls so they never reach the host kernel, and its KVM platform runs the
application on a vCPU. h9 has the same shape: the vmm layer is the platform
and drawterm's kernel is the Sentry, with a Linux syscall table translated
onto it *(planned)*. The differences:

- h9's kernel is Plan 9's, so Linux processes share a machine with 9front
  ones and see 9P servers as ordinary mounts.
- h9 runs on macOS and Windows hosts as well as Linux, and in a browser
  *(planned)*.
- gVisor is a mature, production sandbox. h9's security has had no audit
  (see the warning in the README's [Sandbox](../README.md#sandbox) section).

## Virtual machines

**Firecracker and other microVMs.** Firecracker uses KVM to boot a minimal
Linux guest kernel fast, for serverless and multi-tenant isolation. h9 uses
the hypervisor too, but only to isolate memory and the CPU: there is no guest
kernel, and the guest code in kernel mode is a few hundred lines of shim that
saves registers and exits to the host. So startup is closer to a process
than to a boot, and the host sees and serves every syscall. The trade is that
h9 runs programs, not an operating system: no guest kernel features beyond
what h9 serves, and no devices. If you want complete Linux in isolation, a
microVM is the better tool; the Linux personality proposal says so itself.
h9's closest relative on this axis is
[hyper-linux](https://github.com/zw3rk/hyper-linux), which runs Linux ELF
binaries on macOS's Hypervisor.framework the same way, and whose shim and ELF
loader h9's design draws on.

**WSL.** WSL 1 translated Linux syscalls in the host OS kernel (NT), with no
VM; h9's Linux personality *(planned)* is the same idea, with the translation
in user space behind a hypervisor and onto a Plan 9 kernel rather than NT.
WSL 2 is a lightweight VM with a real Linux kernel, closer to Firecracker. On
Windows h9 will use the Windows Hypervisor Platform
([whp](../design/0017-whp.md), *planned*) the way it uses HVF on macOS, and
runs on the emulator until then.

## Compatibility layers

**Wine.** Wine runs Windows programs on Unix by reimplementing the Windows API
in user space; the program's code runs directly on the host CPU, as an
ordinary host process. h9 is a compatibility layer in the same sense (foreign
binaries, native code, an ABI served by someone else's kernel), for Plan 9
and *(planned)* Linux binaries on macOS, Linux and Windows. But its ABI is a
kernel's syscall table rather than a library API, and h9 runs the guest in a
VM so its code can't touch the host directly. Wine is not a sandbox; h9 is
meant to be one.

**qemu-user and binfmt_misc.** qemu-user runs foreign-architecture Linux
binaries by translating instructions and passing syscalls to the host kernel.
h9-emu translates instructions with Unicorn, which is built on QEMU's CPU
core, but h9 serves the syscalls itself rather than handing them to the host.
The [host-binfmt](../design/host-binfmt.md) draft would register h9 with
`binfmt_misc` the way qemu-user is registered, so `./prog` runs a 9front
binary on Linux without typing `h9`. It matches only 9front's a.out magics:
host Linux binaries still run natively.

## The browser and wasm

**v86.** v86 emulates a whole x86 PC in the browser, and you boot an OS on
it. The [browser-host](../design/0012-browser-host.md) proposal *(planned)*
uses v86 differently: only its CPU core, as an h9 vmm backend, with h9 itself
compiled to wasm. So in a browser tab, as on every other host, a 9front 386
binary runs with no disk image, boot or guest kernel.

**WASI runtimes** (wasmtime, Wasmer, WasmEdge and others). These run portable
wasm modules with capability-style access: preopened directories and granted
sockets, much like h9's namespace allowlist. The difference is the program: a
WASI program is compiled for wasm, while h9 runs existing native binaries and
gives them a whole environment (rc or a Linux shell, `/proc`, `/srv`, 9P,
signals and notes, process trees). The browser host puts h9 on the wasm side
as the host, not as the guest format.

## When h9 fits

- You want 9front's tools (rc, mk, sam, awk, the compilers) as host commands
  or in host pipelines, without running a 9front system.
- You want to run Linux tools *(planned)* in a sandbox on a Mac or Windows
  machine without a Linux VM, or mix them with 9front tools in one pipeline
  and one namespace.
- You want a small, scriptable sandbox with an explicit, printable policy
  (`h9 --print`) for build steps or tools. Remember it's unaudited.
- You want Plan 9's namespace model (`bind`, `mount`, `/srv`, 9P roots) as the
  way to compose what a program can see, on macOS, Linux or Windows, or
  [embedded](embedding.md) in a Zig program.

When it doesn't: if you need complete Linux compatibility, a long-running
managed service, hardware drivers, the 9front kernel itself, or a sandbox
that's been audited, use a container, gVisor, a microVM or 9front in a VM.
