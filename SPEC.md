# Design: h9, a namespace kernel for Plan 9 and Linux executables

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

This describes h9 as built. Changes to it go through proposals in [design/](design/README.md); the record of how h9 got here is in its baselines: [baseline](design/epoch-0/baseline.md) for the work before proposals, and [baseline-1](design/baseline-1.md) for epoch 0.

## Contents

- [Overview](#overview)
- [Decisions](#decisions)
- [Architecture](#architecture)
- [The rest of the spec](#the-rest-of-the-spec)
- [Sources](#sources)

## Overview

h9 is a namespace kernel for Plan 9 and Linux executables: a Zig library and a thin CLI that run 9front and Linux programs directly on macOS, Linux, and Windows, and in a browser. Each run is one machine, a kernel in the host process built on drawterm's Plan 9 kernel, which holds a whole process tree and serves every system call its processes make. Every process has its own namespace, made from host trees, 9P servers, archives, and a built-in root, and the sandbox is that namespace plus a policy the kernel enforces. Programs reach the kernel through one of two ABIs, 9front's and Linux's, picked at exec by the binary's format. Guest code runs on an engine: the host's hypervisor, sud on Linux hosts without one, or h9's own CPUs. Prior art: hyper-linux (Linux ELF on macOS's hypervisor) and 9vx (Plan 9 binaries on Linux and OS X x86 through a vx32 sandbox).

**Goals**

- Start and run a program as fast as a native process: no VM image, no boot, no guest kernel.
- One machine holds a whole process tree, 9front and Linux processes together (rc pipelines, servers posting to /srv, rio and its clients, and Linux tools run from rc), sharing namespaces, fds, pipes, and notes.
- The namespace is how a machine is put together and how it's confined: trees from the host, from 9P servers, and from archives are stacked and bound as on 9front, and what isn't bound can't be reached. The policy is enforced in the kernel, so it's the same on every host and engine.
- Run native code at native speed where the host allows it: arm64 binaries on arm64 hosts and amd64 binaries on x86\_64 hosts, on Hypervisor.framework (macOS), KVM (Linux), and Windows Hypervisor Platform (Windows), or on the sud engine on Linux x86\_64 hosts without KVM.
- Run everywhere else on h9's own CPUs, built into every `h9`: hosts without a usable hypervisor, other architectures' binaries, 386 binaries, and the web host ([hcpu](design/epoch-0/hcpu.md)).
- Work from one binary with nothing else installed ([builtin-root](design/epoch-0/builtin-root.md)).
- Serve a machine's namespace over 9P, so other systems can mount it ([serve](design/epoch-0/serve.md), [kernel-serve](design/epoch-0/kernel-serve.md)).
- Self-hosting: the 9front compilers and mk run inside and can rebuild the 9front userland.

**Non-goals (for now)**

- Running the 9front kernel or a Linux kernel, or drivers for real hardware.
- Plan 9 4th edition or other forks: their syscall tables differ.
- Linux's own namespaces and containers: `mount`, `unshare`, `setns`, and `pivot_root` are refused, since the machine's namespace is the boundary, and `chroot` can only narrow a process's view ([linux-chroot](design/epoch-0/linux-chroot.md)).
- Integrating with the host beyond running as a program, such as `binfmt_misc` registration or serving as a login shell ([host-binfmt](design/epoch-0/host-binfmt.md), [login-shell](design/epoch-0/login-shell.md)).
- A long-running daemon. Each invocation is its own machine.

## Decisions

| Area | Decision | Notes |
| --- | --- | --- |
| Product shape | A library plus a thin CLI; each invocation is one machine | One machine can hold a whole process tree. Keep the machine API free of CLI-global state. |
| Plan 9 flavour | 9front only, at a pinned release | One syscall table and one a.out format per architecture |
| ABIs | Two, picked at exec by the binary's format: 9front's for a.out binaries, and Linux's for ELF binaries on arm64, amd64, and 386 | A Linux process is the same kernel process, with a second syscall table and its own root, the Linux view, with the 9front root at `/9` ([linux-personality](design/epoch-0/linux-personality.md)) |
| Kernel | drawterm's `kern/`, with h9's devices, ABIs, and policy hooks around it in C and Zig | `third_party/drawterm` is a squashed subtree, changed only where necessary and updated only with `scripts/vendor-drawterm.sh` |
| Root filesystem | Mount flags stacked into `#Oroot` behind the kernel's `#/`: host trees, 9P servers over TCP, a unix socket, or a WebSocket, static dotfs trees over HTTP, archives, and the built-in root | A 9P root is mounted through devmnt ([ninep-roots](design/epoch-0/ninep-roots.md), [websocket-9p](design/epoch-0/websocket-9p.md), [mounts](design/epoch-0/mounts.md)); disk images were declined ([image-roots](design/epoch-0/image-roots.md)) |
| Child machines | Under `--children`, a guest starts machines of its own through `#μ`, each another `Machine` in the process sharing the parent's engine and kernel, built from the caller's namespace, and bounded by the parent's plan and what's left of its limits ([child-machines](design/child-machines.md)) | See spec/kernel.md, Child machines |
| Sandbox | The namespace, plus a `Policy` of capabilities, host paths, network rules, and limits that the kernel enforces, with `default` and `tight` profiles | The default root is a copy-on-write overlay with a private `/tmp`, and the network is outbound only ([overlay](design/epoch-0/overlay.md), [ephemeral-writes](design/epoch-0/ephemeral-writes.md), [net-policy](design/epoch-0/net-policy.md)) |
| Serving | The kernel's own 9P2000 server, per connection, on a unix socket, TCP, or a WebSocket; 9P2000.L through the same translator that mounts .L servers | No guest process per connection ([kernel-serve](design/epoch-0/kernel-serve.md), [dotl](design/epoch-0/dotl.md)) |
| Toolchain inside | The 9front compilers (7c/6c, 7l/6l, mk) must run | It's a goal ([self-host](design/epoch-0/self-host.md)), and a source of test binaries |
| Language | Zig 0.17.x (`minimum_zig_version` in `build.zig.zon`) | Change versions deliberately, in a PR of their own, after building and testing on every host. drawterm's C is compiled with `zig cc`. |
| Terminal | Text mode on the host TTY; with `--gfx`, one host window drawn by drawterm's GUI backends ([gfx](design/epoch-0/gfx.md)), or with `--gfx=headless` a screen in memory ([headless-screen](design/epoch-0/headless-screen.md)) | consctl `rawon`; the interrupt key posts an `interrupt` note |
| Hypervisor engines | Hypervisor.framework on macOS (arm64), KVM on Linux (arm64 and x86\_64), and WHP on Windows (x86\_64) | `auto` uses the host's, and falls back to hcpu ([kvm](design/epoch-0/kvm.md), [whp](design/epoch-0/whp.md)) |
| Guest exit mechanism | MMIO doorbell (`OUT` on x86) | Works the same on all three hypervisors |
| Emulator | The hcpu engine, user-mode, on h9's own CPUs, ha64, h86, and hx64 ([hcpu](design/epoch-0/hcpu.md)), built into every `h9` | For hosts and VMs without a usable hypervisor, other architectures' binaries, 386 binaries, and the web host; Unicorn is only a test oracle ([retire-unicorn](design/epoch-0/retire-unicorn.md)) |
| No-hypervisor engine (sud) | On Linux x86\_64, guest code runs on the host CPU in a stub process per address space, with Syscall User Dispatch and seccomp turning its syscalls into exits ([native-backend](design/epoch-0/native-backend.md)) | For containers and cloud VMs without KVM, at native speed; an explicit `--engine sud`, since it shares h9's process and isn't a security boundary, so `auto` never selects it |
| Web host | h9 on wasm32-wasi, with coroutines on JSPI, and guest code on h9's own CPUs (h86 by default, and ha64 and hx64 for Linux programs) | One machine per Web Worker, with graphics on a page's canvas ([browser-gfx](design/epoch-0/browser-gfx.md)); the same build runs under Node for the tests |
| Namespace kernel | A build of the kernel with namespaces and nothing for running programs, as `h9ns.wasm` and a native library | Namespaces are made through `#N` and reached over 9P2000 ([namespace-kernel](design/epoch-0/namespace-kernel.md)) |
| License | MIT, emulator included | GPL and AGPL code (Unicorn, diod, and ZeroFS) is used only by dev and CI tools, never linked into h9 |

## Architecture

Each process, 9front or Linux, runs in user mode on its own vCPU. On a hypervisor, a syscall traps into the shim and exits through the doorbell; on sud and hcpu it becomes the same kind of exit, with no shim. Either way it's served by the kernel on the host, through the process's ABI. The new code is the machine library (highlighted), the engines, and the shims; the CLI is a thin wrapper.

## The rest of the spec

This file is the overview. Each part of h9 is described, as built, in a file under [spec/](spec/):

| File | What it describes |
| --- | --- |
| [spec/engines.md](spec/engines.md) | The `engine` interface; the hypervisor engines (HVF, KVM, and WHP), the sud engine, and the hcpu engine; and the guest shims |
| [spec/jit.md](spec/jit.md), [spec/h86.md](spec/h86.md), [spec/hx64.md](spec/hx64.md), [spec/ha64.md](spec/ha64.md) | h9's own CPUs for the emulator: the layer they share, and each architecture |
| [spec/kernel.md](spec/kernel.md) | The process model; and the kernel: h9's Zig, ported from drawterm's `kern/`, what h9 adds to it, and the drawterm C it still builds |
| [spec/abi-plan9.md](spec/abi-plan9.md) | The 9front binary ABI, a.out loading, the syscall table, and Go programs |
| [spec/abi-linux.md](spec/abi-linux.md) | The Linux ABI |
| [spec/ninep.md](spec/ninep.md) | Mounts and the root, static trees, the 9P dialects, and serving |
| [spec/machine.md](spec/machine.md) | The boot sequence, slim roots, the terminal, and graphics |
| [spec/sandbox.md](spec/sandbox.md) | The security stance and the sandbox policy |
| [spec/cli.md](spec/cli.md) | The CLI: parsing, program resolution, flags, the default guest environment, exit codes, signals, and code structure |
| [spec/host-web.md](spec/host-web.md) | The web host, under Node or in a page |
| [spec/nskernel.md](spec/nskernel.md) | The namespace kernel, for the web host and as a native library |
| [spec/testing.md](spec/testing.md) | Debugging, testing, and CI |

Proposals and other docs written before the split name sections of this file, such as "SPEC.md, Emulator backend". Those sections are now here:

| Section of SPEC.md before the split | Now in |
| --- | --- |
| Hypervisor layer (`vmm`), Native backend (`native`), and Emulator backend (`emu`) | [spec/engines.md](spec/engines.md) |
| Browser host (`web`) | [spec/host-web.md](spec/host-web.md) |
| Guest shims and ABI | The shims in [spec/engines.md](spec/engines.md#guest-shims); the binary ABI, a.out loading, and the syscall table in [spec/abi-plan9.md](spec/abi-plan9.md) |
| Process model | [spec/kernel.md](spec/kernel.md#process-model) |
| Go programs | [spec/abi-plan9.md](spec/abi-plan9.md#go-programs) |
| Linux personality | [spec/abi-linux.md](spec/abi-linux.md) |
| Kernel: h9's Zig and drawterm's C | [spec/kernel.md](spec/kernel.md#kernel-h9s-zig-and-drawterms-c) |
| Filesystem, boot, and I/O | The root filesystem and 9P dialects in [spec/ninep.md](spec/ninep.md); slim roots, the boot sequence, the terminal, and graphics in [spec/machine.md](spec/machine.md) |
| Serving | [spec/ninep.md](spec/ninep.md#serving) |
| Security, debugging, and testing | The security stance and the sandbox policy in [spec/sandbox.md](spec/sandbox.md); debugging, and testing and CI, in [spec/testing.md](spec/testing.md) |
| CLI | [spec/cli.md](spec/cli.md) |

## Sources

- [9front source (GitHub mirror)](https://github.com/9front/9front): `sys/src/9/arm64`, `sys/src/9/pc64`, `sys/src/9/port/sysproc.c`, `sys/include/a.out.h`, `sys/include/tos.h`, `sys/src/libc/9syscall/sys.h`
- [9front drawterm (GitHub mirror)](https://github.com/9front/drawterm): `kern/sysfile.c`, `kern/dat.h`, `kern/devtab.c`, `LICENSE`
- [hyper-linux](https://github.com/zw3rk/hyper-linux): `src/shim.S`, `src/thread.h`, `LICENSE`
- [9front release announcement, OSnews](https://www.osnews.com/?p=145669)
- [isobox](https://github.com/can1357/isobox): capability model, profiles, and plan caveats
