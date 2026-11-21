# Debugging and testing

This describes, as built, h9's debugging aids, its tests, and CI. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Debugging](#debugging)
- [Testing and CI](#testing-and-ci)

## Debugging

- `--trace` logs each syscall with its arguments, result, and error string, prefixed by pid, like 9front's ratrace. When the guest faults, it also logs the Ureg, the faulting address, and a PC symbolized from the a.out symbol table (`dumpFault` in `src/machine.zig`), under the same lock as the syscall lines.
- acid (Plan 9's debugger) attaches to a live process through devproc's `mem`, `regs`, `fpregs`, `text`, and the `ctl` stop messages ([self-host](../design/epoch-0/self-host.md)). A process stops only on its own thread, at a stop point: entering a syscall, delivering a note (which a `stop` kick forces for one spinning in guest code), a breakpoint exit, or before its first instruction after `exec` with `hang`. It saves its Ureg and Extra to its record (`Proc.dbg_ureg`, `dbg_extra` in `src/machine.zig`) and sleeps on the record (`h9_kern_stopwait` in `src/kern/proc.c`), holding no vCPU, so readers on other threads never touch a backend. Register writes are kept in the record and loaded, through `arch.sanitize`, when the process resumes. `mem` reads and writes go through `AddressSpace.copy`; a write into text first gives the process its own copy of a shared text segment (`Segs.ownText`, 9front's `txt2data`) and then calls `codeChanged`, which bumps the flush epoch on hvf and kvm (the shim invalidates the I-cache before its next entry) and makes emu flush Unicorn's whole translation cache before its next run. `kill`, `--timeout`, and teardown interrupt a stopped process.
- `BRK` and `INT3` exit as `vmm.Exit.breakpoint`, and the machine posts `sys: breakpoint` with the debug flag, so a process without a handler dies with it and acid's `bpset`, `step`, and `next` work. The PC is left at the `BRK` on arm64 and after the `INT3` on x86, as on 9front.
- There's no gdb stub.

## Testing and CI

- Unit tests in Zig for the a.out loader, the page allocator, and the syscall decoders.
- Integration tests run real 9front binaries from a pinned root tree. Each case is tagged with the proposal it proves, and skips while that proposal isn't implemented ([design/README.md](../design/README.md#tests)).
- `zig build integration` runs real binaries from the root tree through the `h9` CLI as subprocesses, so each case gets a fresh kernel and checks exit codes end to end; it skips when there's no tree. `zig build proposal -Dp=baseline` runs the baseline's demos and cases. The Lima test VMs get the tree with `scripts/lima/vm push-root`.
- `zig build integration -Dweb` runs the same cases through `h9-node` on h86 with the 386 root, or on ha64 with `-Darch=arm64`; cases that need a host TTY, POSIX signals, TCP, or what a page's WebSocket can't do (headers, a proxy, `--root-ca`, pings) skip there by name or tag. websocket-9p's servers are a native h9 behind `tests/wsrelay.zig`, since the web host can't listen, so those cases need `-Demu=unicorn` as well to run there. `zig build web-test` drives the demo page in Chromium with Playwright (`tests/web/browser.mjs`).
- CI runs `zig build design -- check` on every PR, and the unit and integration tests on PRs from proposal branches ([.github/workflows/ci.yml](../.github/workflows/ci.yml)). Which workflows run what can change without a proposal ([design/README.md](../design/README.md#checks)).
- `zig build workloads` runs real programs (Python, pip, git, sqlite3, 9front's compilers, and `mk`) on a Linux root and a 9front root, in parallel and timed ([tests/workloads](../tests/workloads)), every two days on main ([.github/workflows/workloads.yml](../.github/workflows/workloads.yml)).
