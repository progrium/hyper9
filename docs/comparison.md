# How h9 compares

> A short map from things you may already know to h9. The
> [manual](../MANUAL.md)'s first chapter has a smaller version of this for
> other ways to run Plan 9; this one goes wider, to containers, sandboxes,
> microVMs and compatibility layers. For how h9 works, see
> [DESIGN.md](../DESIGN.md).

## h9 in one paragraph

h9 runs native 9front executables as host commands. Each invocation is one
small Plan 9 machine: every guest process runs in user mode on its own vCPU
from the host hypervisor, and its syscalls exit to a Plan 9 kernel (drawterm's
`kern`) running inside the h9 process. There's no VM image, no boot and no
guest kernel. The guest sees a namespace h9 builds from a root tree (a host
directory or a 9P server), the host cwd, and whatever the sandbox flags bind;
nothing else of the host. Today the hypervisor backend is Hypervisor.framework
on macOS arm64; Linux and Windows run the same programs on the Unicorn
emulator (`h9-emu`), and KVM and WHP backends are
[proposed](../design/0016-kvm.md).

So h9 sits in an unusual spot: it uses hardware virtualization like a
microVM, serves syscalls in user space like gVisor, starts like a native
process, and the thing it runs is Plan 9 userland rather than Linux.

## At a glance

| | What runs | Isolation | Kernel serving syscalls | Starts in | Image/boot |
| --- | --- | --- | --- | --- | --- |
| **h9** | Unmodified 9front binaries | Hypervisor (user mode on a vCPU) plus a namespace allowlist | drawterm's Plan 9 kernel, in the h9 process | Milliseconds | None; a file tree or 9P server is the root |
| 9front in QEMU | The whole 9front system | Full VM | The real 9front kernel, in the guest | Seconds (boot) | Disk image, boot, drivers |
| 9vx | Plan 9 binaries (386) | vx32 software sandbox | A Plan 9 kernel in the 9vx process | Fast | None |
| plan9port | Plan 9 tools recompiled for Unix | None (ordinary Unix processes) | The host kernel | Native | None |
| Docker / OCI | Linux binaries | Linux namespaces, cgroups, seccomp | The shared host Linux kernel | ~100 ms+ | Layered image |
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
them is a Plan 9 kernel.

## Containers and sandboxes

**Docker and OCI containers.** A container is a set of Linux processes on the
host kernel, fenced by namespaces, cgroups and seccomp; on macOS and Windows
it needs a Linux VM underneath. h9 overlaps on the user-facing ideas, from a
different direction:

- **Image vs root.** A container starts from a layered image. h9 starts from a
  root tree, a 9P server ([9p-roots](../design/0013-9p-roots.md)), or one
  behind a WebSocket ([websocket-9p](../design/0021-websocket-9p.md)), and
  composes layers with Plan 9 binds and a copy-on-write overlay device
  (`--write=ephemeral` today; [overlay](../design/0011-overlay.md) as the
  default is accepted). See [userland.md](userland.md) for building your own.
- **Namespaces.** Linux bolted namespaces on; in Plan 9 every process already
  has its own, and the guest can rearrange it with `bind` and `mount` without
  privileges. h9's sandbox is that namespace: anything not bound doesn't exist.
- **Policy.** h9's flags (`--readable`, `--writable`, `--read-deny`,
  `--net=outbound`, `--net-allow`, `--memory`, `--pids`, `--timeout`) are
  enforced in h9's kernel, so they're the same on every host and backend.
- **Exit codes.** 125, 126 and 127 follow `docker run`.
- **What h9 lacks:** a registry, image distribution, a daemon, long-running
  services managed from outside, and Linux binaries
  ([linux-personality](../design/0018-linux-personality.md) is a draft). Each
  invocation is its own machine and ends with its program.

**gVisor.** The closest architecture. gVisor's Sentry is a user-space kernel
that serves a Linux application's syscalls so they never reach the host
kernel, and its KVM platform runs the application on a vCPU. h9 has the same
shape: the vmm layer is the platform and drawterm's kernel is the Sentry (the
[linux-personality](../design/0018-linux-personality.md) draft draws this
analogy itself). The differences are the ABI (Plan 9's is about 50 calls
against Linux's several hundred, which is why one kernel can serve it fully),
that h9 runs on macOS and Windows hosts rather than Linux only, and that h9's
security has had no audit (see the warning in the README's
[Sandbox](../README.md#sandbox) section).

## Virtual machines

**Firecracker and other microVMs.** Firecracker uses KVM to boot a minimal
Linux guest kernel fast, for serverless and multi-tenant isolation. h9 uses
the hypervisor too, but only to isolate memory and the CPU: there is no guest
kernel, and the guest code in kernel mode is a few hundred lines of shim that
saves registers and exits to the host. So startup is closer to a process
than to a boot, and the host can see and serve every syscall. The trade is
that h9 runs Plan 9 programs, not an arbitrary OS, and has no devices beyond
what its kernel serves. Its closest relative on this axis is
[hyper-linux](https://github.com/zw3rk/hyper-linux), which runs Linux ELF
binaries on macOS's Hypervisor.framework the same way, and whose shim h9's
design draws on.

**WSL.** WSL 1 is the same idea as h9's proposed Linux personality, from the
other side: Linux syscalls translated by the host OS kernel (NT), with no VM.
WSL 2 is a lightweight VM with a real Linux kernel, closer to Firecracker. h9
on Windows is neither: it will use the Windows Hypervisor Platform
([whp](../design/0017-whp.md), a draft) the same way it uses HVF on macOS, and
runs on the emulator until then.

## Compatibility layers

**Wine.** Wine runs Windows programs on Unix by reimplementing the Windows API
in user space; the program's code runs directly on the host CPU, as an
ordinary host process. h9 is a compatibility layer in the same sense (foreign
binaries, native code, an ABI served by someone else's kernel), but the ABI is
a kernel's syscall table rather than a library API, and h9 runs the guest in a
VM so its code can't touch the host directly. Wine is not a sandbox; h9 is
meant to be one.

**qemu-user and binfmt_misc.** qemu-user runs foreign-architecture Linux
binaries by translating instructions and passing syscalls to the host kernel.
h9-emu translates instructions with Unicorn, which is built on QEMU's CPU
core, but h9 serves the syscalls itself rather than handing them to the host.
The [host-binfmt](../design/host-binfmt.md) draft would register h9 with
`binfmt_misc` the way qemu-user is registered, so `./prog` runs a 9front
binary on Linux without typing `h9`.

## The browser and wasm

**v86.** v86 emulates a whole x86 PC in the browser, and you boot an OS on it. The accepted
[browser-host](../design/0012-browser-host.md) proposal uses v86 differently:
only its CPU core, as an h9 vmm backend, with h9 itself compiled to wasm. So
in a browser tab, as on every other host, a 9front 386 binary would run with
no disk image, boot or guest kernel.

**WASI runtimes** (wasmtime, Wasmer, WasmEdge and others). These run portable
wasm modules with capability-style access: preopened directories and granted
sockets, much like h9's namespace allowlist. The difference is the program: a
WASI program is compiled for wasm, while h9 runs existing native 9front
binaries and gives them a full Plan 9 environment (rc, `/proc`, `/srv`, 9P,
notes, process trees). The browser host would put h9 on the wasm side as the
host, not as the guest format.

## When h9 fits

- You want 9front's tools (rc, mk, sam, awk, the compilers) as host commands
  or in host pipelines, without running a 9front system.
- You want a small, scriptable sandbox with an explicit, printable policy
  (`h9 --print`) for running untrusted-ish build steps or tools, and you can
  write or build them for 9front. Remember it's unaudited.
- You want Plan 9's namespace model (`bind`, `mount`, `/srv`, 9P roots) as the
  way to compose what a program can see, on macOS, Linux or Windows, or
  [embedded](embedding.md) in a Zig program.

When it doesn't: if you need Linux binaries, a long-running managed service,
hardware drivers, or the 9front kernel itself, use a container, a microVM or
9front in a VM.
