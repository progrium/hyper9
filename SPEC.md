# Design: Plan 9 executables on host hypervisors

Nov 2, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

This describes h9 as built. Changes to it go through proposals in [design/](design/README.md); the record of how h9 got here before proposals is the [baseline](design/epoch-0/baseline.md).

## Contents

- [Overview](#overview)
- [Decisions](#decisions)
- [Architecture](#architecture)
- [The rest of the spec](#the-rest-of-the-spec)
- [Sources](#sources)

## Overview

h9 is a small Zig library and CLI that runs native 9front executables directly on macOS, Linux, and Windows, using each host's hypervisor API. Each guest process runs in hardware-isolated user mode, and its syscalls are served by drawterm's Plan 9 kernel running in the host process. Prior art: hyper-linux (the same shape for Linux ELF on macOS) and 9vx (Plan 9 binaries on Linux and OS X x86 through a vx32 sandbox).

**Goals**

- Start and run a 9front binary as fast as a native process: no VM image, no boot, no guest kernel.
- One invocation can hold a whole process tree (rc pipelines, servers posting to /srv, rio, and its clients).
- Run native code only: arm64 9front binaries on arm64 hosts, amd64 binaries on x86\_64 hosts. 386 binaries run on the emulator, including on the browser host, which has no CPU to run natively on ([i386](design/epoch-0/i386.md), [browser-host](design/epoch-0/browser-host.md)).
- One host backend each for Hypervisor.framework (macOS), KVM (Linux) and Windows Hypervisor Platform (Windows), and a native backend for Linux x86\_64 hosts without KVM.
- Self-hosting: the 9front compilers and mk run inside and can rebuild the 9front userland.

**Non-goals (for now)**

- Running the 9front kernel itself, or drivers for real hardware.
- Translating across architectures (amd64 binaries on arm64 hosts, or the reverse) for users. The emulator can do it, but only for testing.
- Plan 9 4th edition or other forks: their syscall tables differ.
- A long-running daemon. Each invocation is its own machine.

## Decisions

| Area | Decision | Notes |
| --- | --- | --- |
| Product shape | A library plus a thin CLI; each invocation is one machine | One machine can hold a whole process tree. Keep the machine API free of CLI-global state. |
| Plan 9 flavour | 9front only, at a pinned release | One syscall table and one a.out format per architecture |
| Root filesystem | Mount flags stacked into `#Oroot` behind the kernel's `#/`: host trees, 9P servers over TCP, a unix socket, or a WebSocket, static dotfs trees over HTTP, archives, and the built-in root | A 9P root is mounted through devmnt ([ninep-roots](design/epoch-0/ninep-roots.md), [websocket-9p](design/epoch-0/websocket-9p.md), [mounts](design/mounts.md)); disk images were declined ([image-roots](design/epoch-0/image-roots.md)) |
| Toolchain inside | The 9front compilers (7c/6c, 7l/6l, mk) must run | It's a goal ([self-host](design/epoch-0/self-host.md)), and a source of test binaries |
| Language | Zig 0.17.x (`minimum_zig_version` in `build.zig.zon`) | Change versions deliberately, in a PR of their own, after building and testing on every host. drawterm's C is compiled with `zig cc`. |
| Terminal | Text mode on the host TTY; with `--gfx`, one host window drawn by drawterm's GUI backends ([gfx](design/epoch-0/gfx.md)) | consctl `rawon`; the interrupt key posts an `interrupt` note |
| Guest exit mechanism | MMIO doorbell (`OUT` on x86) | Works the same on all three hypervisors |
| Emulator | A user-mode emulator backend on h9's own CPUs, ha64, h86, and hx64 ([hcpu](design/hcpu.md)), built into every `h9` | For development and CI on hosts and VMs without a usable hypervisor |
| No-hypervisor native | On Linux x86\_64, guest code runs on the host CPU in a stub process per address space, with Syscall User Dispatch and seccomp turning its syscalls into exits ([native-backend](design/epoch-0/native-backend.md)) | For containers and cloud VMs without KVM, at native speed; an explicit `--backend native`, since it shares h9's process and isn't a security boundary, so `auto` never selects it |
| Browser host | h9 on wasm32-wasi, with coroutines on JSPI, and 386 binaries on h9's own CPU (h86) | One machine per Web Worker; the same build runs under Node for the tests |

## Architecture

&#91;embedded content: architecture · host process, guest VM, host OS\]

Each Plan 9 process runs in user mode on its own vCPU. A syscall traps into the shim, exits through the doorbell, and is served by drawterm's kernel on the host. The new code is the machine library (highlighted), the vmm backends, and the shims; the CLI is a thin wrapper.

## The rest of the spec

This file is the overview. Each part of h9 is described, as built, in a file under [spec/](spec/):

| File | What it describes |
| --- | --- |
| [spec/engines.md](spec/engines.md) | The `vmm` interface; the hypervisor backends (HVF, KVM, and WHP), the native backend, and the emulator backend; and the guest shims |
| [spec/jit.md](spec/jit.md), [spec/h86.md](spec/h86.md), [spec/hx64.md](spec/hx64.md), [spec/ha64.md](spec/ha64.md) | h9's own CPUs for the emulator: the layer they share, and each architecture |
| [spec/kernel.md](spec/kernel.md) | The process model; and the kernel: drawterm's `kern/`, what h9 adds to it, and the Zig/C seam rules |
| [spec/abi-plan9.md](spec/abi-plan9.md) | The 9front binary ABI, a.out loading, the syscall table, and Go programs |
| [spec/abi-linux.md](spec/abi-linux.md) | The Linux personality |
| [spec/ninep.md](spec/ninep.md) | Mounts and the root, static trees, the 9P dialects, and serving |
| [spec/machine.md](spec/machine.md) | The boot sequence, slim roots, the terminal, and graphics |
| [spec/sandbox.md](spec/sandbox.md) | The security stance and the sandbox policy |
| [spec/cli.md](spec/cli.md) | The CLI: parsing, program resolution, flags, the default guest environment, exit codes, signals, and code structure |
| [spec/host-js.md](spec/host-js.md) | The browser host, and the same build under Node |
| [spec/testing.md](spec/testing.md) | Debugging, testing, and CI |

Proposals and other docs written before the split name sections of this file, such as "SPEC.md, Emulator backend". Those sections are now here:

| Section of SPEC.md before the split | Now in |
| --- | --- |
| Hypervisor layer (`vmm`), Native backend (`native`), and Emulator backend (`emu`) | [spec/engines.md](spec/engines.md) |
| Browser host (`web`) | [spec/host-js.md](spec/host-js.md) |
| Guest shims and ABI | The shims in [spec/engines.md](spec/engines.md#guest-shims); the binary ABI, a.out loading, and the syscall table in [spec/abi-plan9.md](spec/abi-plan9.md) |
| Process model | [spec/kernel.md](spec/kernel.md#process-model) |
| Go programs | [spec/abi-plan9.md](spec/abi-plan9.md#go-programs) |
| Linux personality | [spec/abi-linux.md](spec/abi-linux.md) |
| Kernel: drawterm `kern/` and the Zig seam | [spec/kernel.md](spec/kernel.md#kernel-drawterm-kern-and-the-zig-seam) |
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
