---
slug: child-machines
title: Child machines
status: draft
created: 2026-11-08
authors: [progrium]
depends: []
areas: [kern, vmm, sandbox, cli, guest]
---

# Proposal: Child machines

[Sign here by hand once you've reviewed the whole doc and take responsibility for it, as described under Signature in README.md. Tools and agents never add the signature.]

## Abstract

A program inside a machine can start another machine, a child, by running `h9` with the usual flags. The guest's `h9` is a guest-tools script that talks to a new device, `#μ`, and the outer h9 starts the child in the same host process, on the same backend, at full speed. The child's memory, processes, CPUs, and timeout are carved out of the parent's, its namespace is built from the caller's, and its policy can only be narrower than the parent's. A paravirtual vmm backend, which would let a guest's own h9 build run nested with its own kernel, is left as later work.

## Background

**h9 inside h9 today.** A static musl build of h9 (`zig build -Dtarget=x86_64-linux-musl`) runs under the Linux personality. On an x86\_64 cloud VM without KVM, with the outer machine on the native backend:

```text
$ h9 --root lroot --memory 4g /bin/h9 --check
backend kvm: no /dev/kvm (no KVM in this kernel, or a VM without nested virtualization)
backend native: the kernel has no Syscall User Dispatch (Linux 5.11 or later)
backend auto: no /dev/kvm (no KVM in this kernel, or a VM without nested virtualization)

$ h9 --root lroot --memory 4g /bin/h9 --builtin only --rc 'echo hi'
h9: cannot create auto machine for amd64: no /dev/kvm (no KVM in this kernel, or a VM without nested virtualization)
```

The inner h9 starts, parses its flags, boots its kernel, and runs its probes. It stops at the vmm layer: the guest has no `/dev/kvm`, and the Linux personality's `prctl` answers `PR_SET_SYSCALL_USER_DISPATCH` with `EINVAL`. Separately, h9 has been built inside h9 (a cold `zig build` on the native backend), but the result was run on the host.

**What exists that a child machine can use:**

- **Several machines per host process.** An embedder, or the test suite, can run several `Machine`s in one process. They share the one drawterm kernel, and each first Proc starts with a fresh Pgrp, Fgrp, and Egrp, so each has its own namespace, device mask, console, `/srv` board ([devsrv](0008-devsrv.md)), and environment (DESIGN.md, "Process model").
- **One VM per process on HVF.** `hv_vm_create` succeeds once per host process (`src/vmm/hvf.zig`), so on macOS a second machine can't have a backend of its own. KVM, native, and emu have no such limit.
- **One allocator per backend.** HVF, KVM, and native hand out guest pages, page tables included, from one `gphys.Ram`, reserved at `--memory` bytes; emu uses its arena (`src/vmm/arena.zig`). `--memory` is a cap on that allocator, `--pids` a cap on live processes in `rfork`, and `--cpus` the size of the run-slot pool (`src/cpupool.zig`).
- **devcmd's shape.** `#C` runs host commands through a conversation: `clone`, `ctl` (`dir`, `exec`), `data`, `stderr`, and `wait` ([host-cmd](host-cmd.md)). `hcmd` wraps it.
- **Guest tools.** `#H/bin` puts h9's own rc scripts on the guest's path ([guest-tools](0032-guest-tools.md)).

**Nested runs elsewhere.** [host-binfmt](host-binfmt.md) refuses to start an h9 from a host command a guest ran (`H9_NESTED`), because the new h9 would get the host user's rights and a fresh default policy, broader than the guest's. It leaves "carrying the policy across" open. [login-shell](0089-login-shell.md) uses `H9_NESTED` the same way.

## Proposal

### `#μ`, the machine device

A new device, `src/kern/devmachine.c`, with a Zig half in `src/child.zig`. It's per machine: a machine sees only its own children, as with `/srv`. The namespace builder binds it at `/dev/machine` unless it's masked.

```text
/dev/machine/
  clone          open to get a new child; reads as its number
  n/ctl          options, one per line, then exec
  n/data         the child's console: writes are its input, reads its output
  n/stderr       the child's stderr, when the options ask for it separately
  n/wait         blocks until the child exits; reads as its status
  n/plan         the child's compiled plan, as --print prints it
  n/note         a write posts the note to the child's first process
```

Lines written to `ctl` set options before `exec`. Each matches a host flag, with the same syntax and defaults:

| Line | Flag |
| --- | --- |
| `memory 512m` | `--memory` |
| `pids 32`, `cpus 2`, `timeout 1m` | `--pids`, `--cpus`, `--timeout` |
| `profile tight` | `--profile` |
| `net disable\|outbound\|enable`, `netallow PATTERN` | `--net`, `--net-allow` |
| `write overlay\|ephemeral\|scope\|none` | `--write` |
| `root PATH`, `cwd PATH` | `--root`, the cwd |
| `readable PATH`, `writable PATH`, `readdeny PATH` | `--readable`, `--writable`, `--read-deny` |
| `ns PATH` | `--ns` |
| `env NAME=VALUE` | `--env` |
| `exec PROG ARGS…` | starts the child |

`exec` compiles the child's plan and refuses it (the write fails with the conflict as its error) if it isn't within the parent's, as below. Once started, `ctl` accepts only `kill`. Closing the last fd of a child's conversation kills it, as does the parent's exit: a child never outlives the machine that started it.

`wait` reads as the exit status the CLI would return ([exit-status](0033-exit-status.md)): `0`, a status string, `130` for an interrupt, `124` for a timeout, and so on, so a script gets the same answer either way.

### Paths are the caller's

Every path in a child's options names a file in the namespace of the process that wrote `exec`, not a host path. `root /n/alpine` makes the caller's `/n/alpine` the child's `/`; `readable /usr/glenda/src` binds the caller's `/usr/glenda/src` at the same path in the child, where a host machine would use `/mnt/term/<path>`. Without `root`, the child's root is the caller's `/`; without `cwd`, its cwd is the caller's.

The namespace builder (`src/policy.zig`) already builds a machine's namespace as binds. For a child, each source that would be a `#U` host path is instead a channel walked from the caller's namespace when `exec` runs. Devices are attached fresh for the child: its own `#c` console, `#p` (only its own processes), `#s` board, `#e` environment, and `#O` overlays. So the child can reach only files the caller can reach, and only with the caller's rights, whatever its options say. `n/plan` prints these binds as `bind '<caller path>' <path>` lines, marked `parent` in the access column.

### Limits are carved from the parent's

The child shares the parent's backend: the same `vmm.Backend`, and so the same VM on HVF and KVM, the same RAM memfd on native, and the same arena on emu. Each machine gets a quota on the shared allocator.

- **Memory.** `gphys.Ram` and emu's arena count pages per machine. A child's `memory` is reserved from the parent's remaining quota at `exec`, so a child that wants more than is left fails to start instead of starving the parent later. The child allocates and frees within its quota, and the whole reservation goes back to the parent when it exits. Without `memory`, a child gets half of what the parent has left. Memory that the child's overlays hold counts against the child.
- **Processes.** A child's live processes count against its own `pids` and its parent's. Without `pids`, the parent's remaining count is the child's cap.
- **CPUs.** A child's runs take slots from its parent's `--cpus` pool, as the parent's own processes do. `cpus` caps how many of them the child takes at once.
- **Timeout.** A child's deadline is no later than its parent's. Without `timeout`, it's the parent's.

A grandchild is carved from a child in the same way, so the root machine's limits bound the whole tree.

### Policy can only narrow

At `exec`, the child's compiled plan must be within the parent's, or `exec` fails with the reason:

- **Device mask:** a superset of the parent's. `#C` and `#μ` stay masked in the child if they are in the parent.
- **Network:** `net` no broader (`disable` < `outbound` < `enable`). With the parent under `--net-allow`, every `netallow` pattern must be covered by one of the parent's, and with no `netallow` lines the child inherits the parent's patterns.
- **Writes:** a path the parent can't write is read-only in the child, whatever `writable` says; this follows from binding the caller's channels, and the plan shows it.
- **Profiles:** a child's `profile` applies its defaults, then the rules above.

The parent's policy decides whether children can be started at all: `#μ` is in the device mask unless `--children` is given. `--profile=tight` and `--sandbox` mask it whatever the flags.

### `h9` in the guest

A guest-tools script, `src/guest/bin/h9`, takes the host CLI's flags (those in the table, plus `--rc`, `--print`, and `--`), writes them to a new conversation, runs the program, copies standard input and output through `data`, posts `interrupt` to the child on an interrupt, and exits with `wait`'s status. So this works the same on the host and in a machine:

```sh
h9 --memory 512m --pids 64 --net=disable --rc 'cd /sys/src/cmd && mk'
```

`h9 --print` in the guest prints the child's plan from `n/plan` without starting it. Flags the guest can't use (`--backend`, `--gfx`, `--serve`, `--host-cmd`, `--root` with a URL, `--check`) are a usage error with exit 2.

### The library

`Machine.Options` gains `children: bool` (the device is masked when false). `Machine` gains an internal constructor for a child that takes the parent, the caller's process, and the parsed options, and shares the parent's backend instead of calling `vmm.create`. The quotas are a `Quota` the allocators and `cpupool` take per machine. The public API is otherwise unchanged; an embedder that wants children enables them per machine.

## Rationale

**Delegation, not nesting.** The other ways to run h9 inside h9, compared on this project's x86\_64 cloud VM and from the code:

- **The native backend inside the guest.** The Linux personality would have to provide Syscall User Dispatch, seccomp, memfds shared between processes, `execveat` of a memfd, `clone(CLONE_VM|CLONE_VFORK)`, real SIGSYS frames, and shared futexes across processes, only for this. Each inner syscall would cost four or five outer syscalls and two thread handoffs, which the native backend's spike measured at 1.4 to 27 µs each. amd64 only.
- **The host's `/dev/kvm`, passed through.** Each inner machine would be a real VM beside the outer one, at close to flat speed, but the inner's RAM is scattered 1 MiB chunks of outer memory (a memory slot each), `kvm_run` would need a shadow copy, every ioctl would need checking, and it needs a Linux host with KVM: not the containers and cloud VMs the native backend exists for, and not macOS. Hardware nesting isn't possible, since guests run in user mode under the shim.
- **A paravirtual vmm backend.** See Open issues: it's the right way to run a guest's own h9 build, and the later step, but it's more work than this and every inner syscall goes through two kernels.
- **A host subprocess per child.** The same `#μ` interface, with the outer h9 starting a new host `h9` whose root is the caller's namespace over 9P ([serve](0035-serve.md)'s `exportfs` per connection). It would isolate a crash in the child's kernel from the parent, but every file access would be 9P, a spawn costs milliseconds, memory could only be split by bookkeeping, and the browser host has no subprocesses. It can be added behind the same device later, if isolation turns out to matter more than speed.

A child machine runs at exactly the parent's speed, on every backend and host, needs no hardware or kernel feature, and fits HVF's one VM per process. Most of it exists: several machines per process, devcmd's conversation shape, guest tools, and the namespace builder.

**One kernel.** A child shares the parent's drawterm kernel, as two machines in one process do today. The boundary between them is drawterm's per-Pgrp state and h9's per-machine devices, not a second kernel. That's weaker than nesting, and the Security section says what it means.

**Paths in the caller's namespace.** Host paths would let a guest name host files it can't see, and would make the child's policy depend on what the host's filesystem holds. Building from the caller's channels makes "the child sees no more than the caller" true by construction, not by a check that could drift.

**Reserving memory up front.** Overcommitting would let children start that the parent can't feed, and the first to touch its pages would fail somewhere unrelated. A reservation makes failure happen at `exec`, with a clear error.

**A device, not a syscall.** Files work from rc, from any language, through `exportfs`, and from the Linux view through `/9`; a new syscall would need libc support in every one of them.

**`--children` off by default.** Starting machines is a new capability; the default profile shouldn't gain it silently.

## Compatibility

- **CLI:** new flag `--children`. No change without it.
- **`Machine.Options`:** new field `children`, false by default.
- **Sandbox:** a new capability, `proc.children`, listed by `--print` when enabled, with the caveat that children share the machine's kernel. The default and tight profiles don't enable it.
- **Root tree:** unchanged. The guest's `h9` is in `#H/bin`, after the root's `/bin`, so a root that has its own `h9` wins.
- **`third_party/`:** none.

## Security

The guest gains the ability to start machines, only under `--children`. What a child can reach is bounded by the caller: files through the caller's channels, network by the parent's rules, devices by the parent's mask, and memory, processes, CPUs, and time by the parent's quotas. A child can't start a host process or reach a host path the parent couldn't, and `#C` stays masked if the parent's is.

A child shares the parent's kernel and host process. A bug in drawterm's kernel that one machine can trigger affects every machine in the process, as it does for embedders that run several machines today; [host-sandbox](host-sandbox.md) is the defence in depth for that. The parent can read its children's `plan`, console, and status, but not their memory or `/proc`; children can't see their parent or siblings.

## Done when

```sh
h9 --children --memory 1g --rc 'h9 --memory 256m --rc ''echo $nproc; cat /dev/sysname'''
h9 --children --memory 512m --rc 'h9 --memory 1g --rc date'                # refused: more than the parent has
h9 --children --net=disable --rc 'h9 --net=enable --rc date'                # refused: broader than the parent
h9 --children --rc 'h9 --print --readable /usr/glenda --rc date'            # the child's plan
h9 --rc 'h9 --rc date'                                                       # no --children: h9 says children are off
```

Integration cases, tagged `[child-machines]`:

- `test "a child runs and its exit status comes back [child-machines]"`
- `test "a child's memory is reserved from the parent's and returned at exit [child-machines]"`
- `test "a child that wants more memory than is left fails at exec [child-machines]"`
- `test "a child's processes count against the parent's pids [child-machines]"`
- `test "a child can't broaden the network policy [child-machines]"`
- `test "a child sees only the caller's namespace [child-machines]"`
- `test "a child can't write what the caller can't [child-machines]"`
- `test "an interrupt reaches the child, and the parent's exit kills it [child-machines]"`
- `test "a grandchild is bounded by the root machine [child-machines]"`
- `test "a Linux program starts a child through /9 [child-machines]"`
- `test "children are masked without --children and under --profile=tight [child-machines]"`

The cases run on every backend, including HVF, where a second VM in the process is impossible.

## Implementation

1. Per-machine quotas in `gphys.Ram`, emu's arena, and `cpupool`, with the root machine's quota as its `--memory` and `--cpus`. No behaviour change for one machine.
2. Sharing a backend between machines: a `Machine` constructor that takes the parent's backend, and a backend lifetime that ends with the last machine using it.
3. The namespace builder taking channels from a caller's namespace in place of `#U` paths, and printing them.
4. `#μ`, the conversation, `exec`, `wait`, `note`, `plan`, and the narrowing checks, with `--children` and `proc.children`.
5. `src/guest/bin/h9` and its flag parsing.
6. The cases, MANUAL.md (a section on children), README, and DESIGN.md; set `status: implemented`.

## Open issues

- **True nesting, the later step.** A paravirtual vmm backend, `nest`, would let a guest run its own h9 build, with its own kernel, nested. The outer kernel would serve the vmm contract through a device: a `ram` file the inner h9 maps at `--memory` (allocated from the outer's RAM, so counted against it), a `clone` per address space with `map`, `unmap`, `protect`, and `codechanged` in its `ctl`, and per vCPU a `run` file that takes a Ureg and Extra and blocks until the next exit, with a note as the kick. The outer runs a nested space on the host thread already serving the inner h9's `run`, so compute runs at full speed and an inner syscall costs two outer exits plus the inner kernel's own calls. It works on every outer backend, since it needs only `newAddressSpace`, `map` of the outer's own pages, and `run`, and the experiment in Background shows everything above the vmm layer already runs nested. It wants its own proposal once a guest needs a different h9 than the one running it, such as for testing h9 inside h9.
- **The device's name.** `#μ` follows `#λ` and `#ℏ`; a letter would be easier to type, but `M`, `m`, `C`, and `c` are taken.
- **The Linux view.** A Linux program can reach the device's files through the Linux view's `/9`, but the `h9` on a Linux root's `PATH`, if any, is the Linux binary, not the guest-tools script. Whether that binary should act as a client when it finds the device, so `h9` does the same thing in both views, is undecided.
- **A different architecture or backend for a child.** A child of 386 binaries on an amd64 parent would need a second backend in the process (emu), with its own memory, so it can't share the parent's quota as simply. Refused for now.
- **Default memory.** Half of what the parent has left is a guess; a fixed default such as `--memory`'s 1 GiB, capped at what's left, is the alternative.
