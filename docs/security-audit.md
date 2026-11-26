# h9's sandbox: a brief for security auditors

This is the starting point for an audit of h9's sandbox: what h9 is, what it
promises to contain, who it defends against, where the boundaries are, which
code is in scope, what has been hardened, what is known to be weak, and how
to build and test it. It describes the tree at the commit it was last
updated with (see [Revision](#revision)) and points into the spec, the
design proposals, and the source for detail. Where this brief and
[SPEC.md](../SPEC.md) or [spec/](../spec/) differ, the spec describes what's
built.

> **Status.** h9 is a research prototype and its sandbox has not been
> audited. The manual says so ([MANUAL.md, chapter 23](../MANUAL.md#23-sandboxing)),
> and so do [docs/comparison.md](comparison.md) and
> [docs/containers.md](containers.md). One internal review (Nov 9, 2026)
> found that the sud engine can't contain a guest (see
> [Known gaps](#10-known-gaps-and-accepted-risks)), and `auto` stopped choosing
> it.

## Contents

1. [What h9 is](#1-what-h9-is)
2. [What the sandbox promises](#2-what-the-sandbox-promises)
3. [Threat model](#3-threat-model)
4. [Trust boundaries](#4-trust-boundaries)
5. [The sandbox policy and the plan](#5-the-sandbox-policy-and-the-plan)
6. [Attack surface](#6-attack-surface)
7. [Recent and pending changes](#7-recent-and-pending-changes)
8. [Scope](#8-scope)
9. [Hardening already done](#9-hardening-already-done)
10. [Known gaps and accepted risks](#10-known-gaps-and-accepted-risks)
11. [Suggested focus](#11-suggested-focus)
12. [An audit plan](#12-an-audit-plan)
13. [Building, running, and testing](#13-building-running-and-testing)
14. [Reference map](#14-reference-map)

## 1. What h9 is

h9 is a Zig library and a thin CLI that runs native 9front executables, and
Linux ELF executables beside them, on macOS, Linux, and Windows. There's no
guest kernel and no VM image. Each guest process runs in user mode on its own
virtual CPU in one VM per h9 process, and every system call it makes exits to
the host, where a Plan 9 kernel (drawterm's `kern/`, vendored, plus h9's
additions) serves it inside the h9 process. A Linux program's calls are
translated onto the same kernel. The kernel's per-machine namespace is the
only route from a guest to the host's files, network, and devices.

```text
 host OS process: h9 (runs as the invoking user, not host-sandboxed)
 ┌───────────────────────────────────────────────────────────────────────┐
 │ CLI (src/cli.zig, src/main.zig) ── plan ──▶ Machine (src/machine.zig)  │
 │                                                                       │
 │ Policy (src/policy.zig) ◀── leaf calls ── kernel: drawterm kern/ + h9  │
 │   access rules, net rules,                devices (src/kern/*.c)       │
 │   resolved-name table                     devfs #U ──▶ host files      │
 │                                           devip #I ──▶ host sockets    │
 │ ABIs: src/abi/plan9/ (9front),            devmnt+#ℓ+#ι ──▶ 9P servers  │
 │   src/abi/linux/ (Linux)                  #ℏ ──▶ WebSockets (TLS)      │
 │                                                                       │
 │ engine (src/engine.zig): hvf | kvm | whp | sud | hcpu (JIT)           │
 └──────────────▲───────────────────────────────────────────▲────────────┘
                │ doorbell exit (MMIO store / OUT)           │ guest memory
 ┌──────────────┴───────────────────────────────────────────┴────────────┐
 │ guest: user-mode 9front or Linux code, one vCPU per process           │
 │ shim (src/arch/*/shim.S) in guest kernel mode: save/restore, no policy │
 └───────────────────────────────────────────────────────────────────────┘
```

Read [SPEC.md](../SPEC.md) for the overview and decisions, and
[spec/sandbox.md](../spec/sandbox.md) for the security stance as built.

## 2. What the sandbox promises

These are the properties h9 means to hold, so they're the ones an audit
should try to break. "Guest" means any code running in the machine, 9front
or Linux, on any security-boundary engine (HVF, KVM, WHP, or the emulator).

1. **No host system calls.** Guest code can't make a host system call, ioctl,
   or other host-kernel request directly. Every call is served by h9's
   kernel.
2. **No access to h9's memory.** Guest code can read and write only the
   guest-physical pages its address space maps, and h9 reads guest memory
   only through checked translation.
3. **The namespace is the allowlist.** A guest reaches host files only
   through `#U` binds the plan made, each read-only or read-write, filtered
   by the access rules (deny wins, then the longest allow). Unbound host
   paths don't exist, and a masked device (`#U`, `#I`, `#C`, `#ℏ`, `#ι`,
   and others) can't be attached again.
4. **Writes stay where the plan says.** By default the root is a
   copy-on-write overlay in memory and only the host working directory is
   writable. `--write=none`, `scope`, `ephemeral`, and `overlay` narrow or
   redirect writes.
5. **The network is what the plan says.** `--net=disable` masks `#I` and
   `#ℏ`. `outbound` refuses every `announce`. `--net-allow` patterns are
   the whole egress policy, by address, CIDR, port, and name. Link-local
   addresses (including cloud metadata at 169.254.169.254) are refused
   without a pattern.
6. **No host environment.** The host's environment variables never reach
   the guest; the guest gets fixed defaults and `--env`.
7. **Limits hold.** `--memory` is an exact cap on guest-physical pages
   (overlay data and Linux page cache included), `--pids` caps live
   processes, `--cpus` caps running vCPUs, and `--timeout` tears the
   machine down.
8. **Machines are separate.** Several machines in one h9 process (an
   embedder's, or the test suite's) can't see each other's processes,
   `/srv` posts, overlays, unions, consoles, or environments.
9. **The plan is honest.** `--print` shows what will be enforced, every
   bind with its access, the device mask, and the caveats below.

What it doesn't promise is listed under
[Known gaps](#10-known-gaps-and-accepted-risks): above all, the h9 process
itself runs with the host user's full rights, so a memory-safety bug in
h9's kernel, device, or translator code reachable from a guest is a sandbox
escape.

## 3. Threat model

### Assets

- **Host files** outside the plan's paths, and the integrity of host files
  inside read-only paths.
- **The h9 process**: its memory, which holds host pointers (overlay nodes,
  translators' state, TLS sessions), and code execution in it, which is code
  execution as the host user.
- **Host network reach**: the host's loopback services, its LAN, cloud
  metadata endpoints, and arbitrary internet egress.
- **Secrets on the host**: environment variables, credential-helper output
  and headers, `--serve-token`, files under `--read-deny`.
- **Other machines** in the same h9 process, and other h9 processes'
  `--serve` listeners.
- **Host resources**: memory, threads, file descriptors, disk under writable
  paths, and the index cache (`--index-cache`).

### Adversaries

| ID | Adversary | Controls | Wants |
| --- | --- | --- | --- |
| A1 | A malicious guest program (9front a.out, Linux ELF, Go, a `#!` script) | Every instruction and syscall argument it runs, every file it writes in the machine, timing and threads | Any asset above |
| A2 | A malicious or compromised file server: a 9P server over TCP, a unix socket, or a WebSocket; a static dotfs tree over HTTP; a `.fs/index` or `.fs/events` stream | Every byte of every reply, the dialect it speaks, `9P-Uid`/`9P-User` headers, symlink targets, index contents, timing | Code execution in h9, files outside the mount, the credential helper's headers |
| A3 | A network peer of a `--serve` listener (unix, TCP, or `ws://`) | Connection bytes, HTTP upgrade headers, `Origin`, 9P2000 or 9P2000.L requests | The served namespace beyond what the token and root allow, code execution in h9 |
| A4 | Another machine in the same host process | The same as A1, inside its own machine | Another machine's processes, files, and posts |
| A5 | A host process racing h9 on the file system | Renames, symlink swaps, and hardlinks in directories the plan binds | Turning a guest operation into one on a path outside the plan |
| A6 | A web page or the network, against the web host | Messages to the Worker, WebSocket servers | The page's origin beyond the machine's grant |

### Trusted, and out of the model

- **The person who writes the plan.** Flags, `--ns` files, `--cred`
  commands, `--user-map` files, and (once [plan-format](../design/plan-format.md)
  lands) plan files are as trusted as a command line. A plan that binds `~`
  read-write gives the guest `~`.
- **The host OS kernel, the hypervisor, and the CPU.** Hypervisor escapes and
  CPU side channels (Spectre-class, timing across vCPUs) are out of scope
  for this audit, though findings about how h9 configures the hypervisor
  (CPUID, system registers, page tables) are in.
- **The 9front and Linux binaries in a trusted root**, unless the audit
  takes the root itself as A2's.
- **The sud engine.** It's documented as not a boundary and needs
  `--engine sud`; findings there are informational.

## 4. Trust boundaries

| # | Boundary | Where it's enforced | Crossed by |
| --- | --- | --- | --- |
| B1 | Guest CPU and memory vs. the h9 process | The hypervisor's stage-2 tables and h9's page tables (`src/engine/{hvf,kvm,whp}.zig`, `pt_arm64.zig`, `pt_amd64.zig`, `gphys.zig`); on the emulator, hcpu's software TLB and region checks (`src/engine/hcpu/interp/mem.zig`, `src/engine/hcpu/jit/`) | Every exit, every page fault, `AddressSpace.translate` and `copy` |
| B2 | Guest kernel mode (the shim) vs. guest user mode | The shim's entry and restore paths (`src/arch/{amd64,arm64}/shim.S`), the host-set CPU state (`src/engine/x86.zig`), `arch.sanitize` (`src/arch/*.zig`) | Syscalls, faults, notes, `noted`, `rt_sigreturn`, `/proc/n/regs` writes |
| B3 | Syscall arguments vs. the kernel | `src/abi/plan9/syscall.zig` (9front) and `src/abi/linux/sys.zig`, `mm.zig`, `signal.zig`, and the rest of `src/abi/linux/`; `GuestBuf` (see [kernel.md, seam rule 7](../spec/kernel.md#zigc-seam-rules)) | Every syscall |
| B4 | The guest's namespace vs. the host's file system | The namespace builder (`src/newns.zig`, `src/mount.zig`, `src/machine.zig`), the device mask, and devfs's hooks into `src/kern/fscheck.c` and `h9_policy_check` in `src/policy.zig` | Walks, opens, creates, removes, renames, wstats, directory reads on `#U` |
| B5 | The guest's network vs. the host's | devip's hooks (`h9_net_check`, `h9_net_lookup`, `h9_net_resolved`) into `src/kern/netcheck.zig` and `src/policy.zig`; devhstream's connect check; the Linux socket layer (`src/kern/linuxnet.zig`) | `connect`, `announce`, `cs` lookups, `sendto`, `/net/ws` |
| B6 | Remote servers' bytes vs. h9's parsers | `src/dotl/` (`wire.zig`, `client.zig`, `server.zig`, `attr.zig`), `src/rootindex/`, `src/rootindex.zig`, `src/statictree.zig`, `src/hstream.zig`, `src/ws.zig`, and drawterm's devmnt | Every 9P reply, index, event record, HTTP response, and WebSocket frame |
| B7 | Network clients vs. a served machine | `src/serve.zig`, `src/ws.zig`'s server side, `src/dotl/server.zig`, exportfs in the guest | Connections to `--serve` listeners |
| B8 | One machine vs. another in the same process | Per-machine lookups in devproc, devsrv, `#O`, `#ℏ`, `#ℓ`, the console, and devenv (`src/kern/`) | Any path that names a pid, a post, a union number, or a conversation |
| B9 | The web host's Worker vs. the page | wasm's memory safety, `src/web/`, the JS host (`h9-web.js`, `worker.js`) | Worker messages, imports |

## 5. The sandbox policy and the plan

The policy is a `Policy` in `Machine.Options`: capabilities, host paths,
network rules, and limits. The CLI compiles flags into it, `--print` prints
the result (the plan) and exits, and the machine enforces it. The model
follows isobox's named capabilities, profiles, and caveats, but enforcement
lives in the shared kernel, so the capability set is the same on every
engine.

- **Capabilities, default profile, `tight`, and `--sandbox DIR`:**
  [spec/sandbox.md](../spec/sandbox.md#sandbox-policy) and
  [MANUAL.md, chapter 23](../MANUAL.md#23-sandboxing).
- **Where it's compiled:** `src/cli.zig` (flags), `src/main.zig` (host-side
  resolution of paths and roots), `src/policy.zig` (access rules, net
  rules, the verdict leaves, and `--print`), and `src/newns.zig` and
  `src/mount.zig` (the namespace).
- **The plan format** ([plan-format](../design/plan-format.md), draft) makes
  the plan a complete text format in namespace-file syntax: namespace
  lines, policy lines (`net`, `netallow`, `write`, `deny`, `devices`,
  `profile`), and limit and run lines. It becomes the one input of the CLI
  (`--plan FILE`), the Zig API, the page's `createMachine`, and a child
  machine's `ctl`, and flags given after `--plan` can only narrow it. Its
  Security section names the narrowing rule as the security property, with
  one implementation shared by flags and child machines. Today `--print`'s
  namespace replays through `--ns`, and the rest of the plan is display
  only.

The default `--print` output lists its caveats, which are a good summary of
the accepted risks:

```text
caveats:
  - writes to the root are kept in memory, count against --memory, and are lost when the machine ends; ...
  - a file opened for writing is copied into memory whole the first time
  - hardlinks under writable paths can modify host files outside them
  - writes to writable paths are not capped (no res.disk)
  - paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check
  - /proc/n/ns shows the host paths of bound host trees
  - the h9 process itself is not host-sandboxed
```

## 6. Attack surface

### 6.1 Execution engines

`engine.create` picks an engine: `auto` tries the host's hypervisor, then
hcpu, and never picks sud. See [spec/engines.md](../spec/engines.md).

| Engine | Host | Isolation | Host-facing code | What to look at |
| --- | --- | --- | --- | --- |
| HVF | macOS arm64 | Hypervisor.framework; EL1 shim, TTBR0 user and TTBR1 kernel halves | `src/engine/hvf.zig`, `pt_arm64.zig`, `gphys.zig`, `src/arch/arm64/shim.S` | System register values the host sets, the kernel half's mappings (the shim, the doorbell page, the per-vCPU shared pages) and whether any is user-accessible, `codeChanged` and I-cache flushes, unmap and remap of released ranges |
| KVM | Linux x86\_64 and arm64 | `/dev/kvm`, one memory slot at 2 GiB, no in-kernel irqchip | `src/engine/kvm.zig`, `kvm_abi.zig`, `pt_amd64.zig`, `x86.zig`, `src/arch/amd64/shim.S` | CR0/CR4/EFER, SMEP and SMAP, the GDT/TSS/IDT and IST, `STAR`/`LSTAR`/`SFMASK`, `SWAPGS` handling, CPUID masking, vCPU recycling (a parked vCPU's full reset), the kick signal (`SIGRTMIN + 1`) and `immediate_exit`, `KVM_SET_ONE_REG` on arm64, TSC offset |
| WHP | Windows x86\_64 | Windows Hypervisor Platform, KVM's shim and page tables | `src/engine/whp.zig`, `whp_abi.zig` | The same CPU state set through `WHvSetVirtualProcessorRegisters`, the cancel and flag kick, vCPU reset, the runtime-loaded `WinHvPlatform.dll` |
| hcpu | Every host, and the browser | Software: no guest kernel mode, no MMU; every access bounds-checked against the arena | `src/engine/hcpu/engine.zig`, `h86.zig`, `ha64.zig`, `hx64.zig`, `interp/`, `jit/`, and `src/engine/arena.zig` | The software TLB (a fill is the permission check), T1's inline TLB check and slow paths, code-page invalidation races, W^X code memory (`src/engine/hcpu/jit/codemem.zig`: `MAP_JIT` on macOS, a dual-mapped memfd on Linux, one RWX mapping only under a binary translator), the JIT's region and chain-cell handling, the wasm emitter on the web |
| sud | Linux x86\_64 | **None that holds.** A stub process per address space, Syscall User Dispatch, and a seccomp backstop | `src/engine/sud.zig`, `sud_stub.zig`, `sud_abi.zig` | Informational only: see Known gaps |

The interface's contract is in Plan 9 terms, so the code above the engine layer
is shared. [spec/jit.md](../spec/jit.md), [spec/h86.md](../spec/h86.md),
[spec/hx64.md](../spec/hx64.md), and [spec/ha64.md](../spec/ha64.md) describe
the CPUs.

### 6.2 The shim, registers, and notes

- **Exits.** The shim saves the Ureg to the per-vCPU shared page and stores
  to an unmapped doorbell (arm64) or does an `OUT` (x86). The host reads and
  writes the shared page directly. A kick can stop a vCPU mid-shim: the host
  tells save from restore by the PC and runs a half-saved Ureg on to the
  doorbell ([engines.md, KVM](../spec/engines.md#kvm)).
- **Register state the guest controls.** `arch.sanitize`
  (`src/arch/{amd64,arm64,i386}.zig`) bounds what a note handler's `noted`
  and a debugger's `regs` write can set: on amd64 the user selectors, the
  low flag byte, and a masked PC. The Linux ABI's `rt_sigreturn`
  restores only NZCV on arm64, and on amd64 the user flags with `cs` and
  `ss` kept and a canonical `rip` ([abi-linux.md, Signals](../spec/abi-linux.md#signals)).
  `arch_prctl` sets FS and GS bases (`X86Extra`).
- **CPUID.** KVM's shim hides XSAVE, AVX, AVX-512, AMX, and AVX10, so only
  FXSAVE state crosses vCPUs. The emulators answer for themselves. The
  sud engine can't hide CPUID.
- **Debugging.** devproc's `mem`, `regs`, `fpregs`, and `text` and the
  `ctl` stop messages let one guest process read and write another's
  memory and registers within the machine, as on 9front. Writes into text
  give the process its own copy and call `codeChanged`.

### 6.3 9front system calls

- **Decode and memory.** `src/abi/plan9/syscall.zig` decodes 9front's table (numbers
  0 to 53; unknown and old calls post "sys: bad sys call"). drawterm's
  `validaddr` is a no-op, so `GuestBuf` is the only check that a guest
  buffer is mapped: contiguous buffers are passed in place, others bounce,
  buffers of 1 GiB or more are split (drawterm's `long` is 32 bits), and
  strings are copied into bounded host buffers first so another guest thread
  can't change them mid-call. Any unmapped byte posts "sys: bad address in
  syscall".
- **Loading.** `src/abi/plan9/aout.zig` and `src/abi/plan9/loader.zig` parse the a.out header
  (40 bytes on 64-bit magics, 32 on 386) and map text, data, and bss
  ([abi-plan9.md](../spec/abi-plan9.md#aout-loading-host-side)).
- **Processes and memory.** `src/segment.zig` and `src/machine.zig`: rfork
  (eager copy, or shared with `RFMEM`), exec, `brk_`, `segattach` (up to
  five, never executable), `segbrk`, `segfree`, and notes. `src/cpupool.zig`
  hands Ureg and FP state between process and pool threads past the vCPU
  limit.
- **Semaphores and rendezvous.** `src/kern/sema.c`: wait lists keyed by the
  host address of the guest word, with `src/abi/plan9/syscall.zig` checking the word
  is aligned, mapped, and in a writable segment.
- **mount.** A guest may `mount` any 9P server it has an fd for (a posted
  channel, its own pipe, or a network connection the policy allowed), so
  devmnt's client is guest-reachable with guest-chosen servers (see 6.8).

### 6.4 The Linux ABI

The largest single surface: `src/abi/linux/sys.zig` (about 7,000 lines) and its
neighbours. See [spec/abi-linux.md](../spec/abi-linux.md).

- **Loading** (`src/abi/linux/elf.zig`, `exec.zig`): static and dynamic ELF for
  arm64, amd64, and i386, `PT_INTERP` read in the Linux view, lazily filled
  file mappings, the vDSO and the read-only clock page (`src/abi/linux/vclock.zig`).
- **Memory** (`src/abi/linux/mm.zig`, `pagecache.zig`, `shmfile.zig`,
  `sysvshm.zig`): VMAs, lazy 64 KiB chunks, copy-on-write fork, shared file
  mappings kept coherent with `read` and `write`, a page cache shared by
  every Mm of every machine on an engine, System V shared memory, and
  shootdowns before freeing. Look for use-after-free across threads and
  forks, reference counts on shared chunks, and the `--memory` accounting.
- **Identity.** A Linux process starts as uid 0 and the `set*id` calls work
  as on Linux, but uid grants nothing: permission checks stay with the
  namespace and the policy. `stat` reports the caller's effective ids.
- **Files.** `link` copies, `rename` across directories is the host's
  `rename(2)` within host trees, `symlink` makes host links in `#U` trees
  (checked as a create), `mkfifo` makes host FIFOs, record and `flock` locks
  are one table per h9 process, `fsync` reaches the host.
- **Symlinks** ([linux-symlinks](../design/epoch-0/linux-symlinks.md)): a Linux
  process's walk stops at a link, and the kernel follows it from the
  process's root, so a link in a bound host tree to a host path the guest
  doesn't see is `ENOENT`. The host open is `openat2` with
  `RESOLVE_NO_SYMLINKS`, or a chain of `O_NOFOLLOW` opens.
- **chroot** (see 7.1).
- **Refused:** `mount`, `umount2`, `pivot_root`, `unshare`, and `setns`
  (`EPERM`); `clone` flags outside glibc's, musl's, and Go's sets
  (`EINVAL`); `WAKE_OP` and PI futexes (`ENOSYS`); inotify (`ENOSYS`, until
  file-watch).
- **Signals** (`src/abi/linux/signal.zig`): frame layout, `rt_sigreturn`,
  `sigaltstack`, signalfd, itimers (`src/abi/linux/itimer.zig`).
- **Threads**: `clone`, futexes in `src/kern/linux.c`, robust lists,
  `clear_child_tid`, `exit_group`, `execve` from a non-leader.
- **Terminals**: the console's termios, and pseudoterminals in
  `src/kern/dev/pty.zig` with an `N_TTY`-like line discipline. There are no host
  ioctls such as `TIOCSTI`.
- **Sockets** (`src/kern/linuxnet.zig`): `socket(2)` opens `/net/tcp/clone` in
  the process's namespace, so devip's policy applies. `sendto` is checked
  against the connect policy. `AF_UNIX` sockets are pipes posted in `#s`,
  `SCM_RIGHTS` passes fds within one machine, and `AF_NETLINK` answers link
  and address dumps from the host's interfaces (`src/abi/linux/netlink.zig`).
- **`/proc` and `/sys`** are synthesized by `#L` (`src/kern/devlinux.c`).

### 6.5 Kernel devices

drawterm's devices reused as-is include devroot, devcons, devmnt, devlfd,
devfs (posix and win32, with h9's hooks), devpipe, devip (with h9's hooks),
devtls, devssl, devdraw, devmouse, devaudio, and qio. h9 adds devices in
`src/kern/` ([kernel.md, Added by us](../spec/kernel.md#added-by-us)):

| Device | File | Security-relevant property |
| --- | --- | --- |
| `#y` console | `devhcons.c` | Per machine, through Zig leaves |
| `#e` env | `devenv.c` (from 9front) | Per Egrp; never imports the host environment |
| `#p` proc | `devproc.c` (from 9front) | Looks every pid up in the caller's machine |
| `#d` dup | `devdup.c` | `/fd/N` |
| `#s` srv | `devsrv.c` (from 9front) | One board per machine |
| `#O` overlay and unions | `devoverlay.c` (about 6,000 lines) | Attaching checks the instance belongs to the caller's machine; memory from the guest-physical allocator; union walk cache keyed by the caller's access rules |
| `#L` Linux view | `devlinux.c`, `linux.c` | The Linux root, `/proc`, `/sys`, `/dev`, chroot |
| `#ε` eventfd/epoll | `dev/eventfd.zig` | Readiness |
| `#τ` pty | `dev/pty.zig` | Per machine numbering |
| `#ℏ` host streams | `devhstream.c`, `src/hstream.zig`, `src/ws.zig` | Guest `/net/ws` connects are checked by the net policy; up to 32 conversations and 16 MiB unread per stream |
| `#ℓ` 9P2000.L | `devdotl.c`, `src/dotl/` | Translator between devmnt and a server, or a client and exportfs |
| `#ι` index | `devhidx.c`, `src/rootindex/` | Masked once `--ns` is replayed, since it could reach the host's index cache |
| `#H` tools and built-in root | `devhtools.c` | Constant data; refuses every write |
| `#C` host commands | (not built) | Always masked ([host-cmd](../design/host-cmd.md) is a draft) |
| FIFOs | `fifo.c` | One table per h9 process, keyed by file identity |

The vendored files h9 changed, each change marked, are `chan.c`, `devcons.c`,
`devfs-posix.c`, `devfs-win32.c`, `devip.c`, `devpipe.c`, `qio.c`, and
`sysfile.c` under `third_party/drawterm/kern/`.

### 6.6 The host file system

The rules are in [spec/sandbox.md](../spec/sandbox.md#access-rules), and the
code is `src/kern/fscheck.c` (about 1,500 lines) and `h9_policy_check` in
`src/policy.zig`.

- **Access rules.** The root, the cwd, each `--readable`, `--writable`, and
  `--dir` path, and each `--read-deny` path, as resolved host paths. Deny
  wins, then the longest allow decides read-only or read-write. Ancestors of
  allowed paths can be walked and listed but not changed. Everything else is
  hidden. Bind-level read-only (no `MCREATE`) is a second check.
- **Path resolution.** Every devfs path is resolved before it's checked: on
  Linux one `openat2(RESOLVE_NO_SYMLINKS)`, else an `O_PATH` open and its
  `/proc/self/fd` name; `realpath` on macOS, older Linux, and the web host;
  on Windows the final path of an opened handle, refusing UNC and device
  paths. Create, remove, and rename check the name, not a link's target (on
  macOS `F_GETPATH` on an `O_SYMLINK` open; on Windows a reparse-point open,
  so case, 8.3 names, and trailing dots can't dodge a rule). Renaming a
  directory with a rule beneath it is refused.
- **Contained trees** (`#U!c`, `--dir PATH:DST:contained`, and every `#L`
  `--dir`): devfs resolves links itself, one name at a time with `lstat`,
  as `RESOLVE_IN_ROOT` does, with a 40-link limit; on Windows through
  `FSCTL_GET_REPARSE_POINT`, refusing other reparse points and UNC targets.
- **9front vs. Linux walks.** A 9front program's devfs walk follows host
  symlinks (then checks the result); a Linux program's stops at the link.
  Both paths are in scope.
- **The overlay** (`#O`) keeps copies, whiteouts, markers, and links in
  memory over a lower chan, so every lower lookup goes through devfs's
  checks. Copies are allocated from guest-physical pages and count against
  `--memory`.
- **`--host-fs`** exposes all of `#U`, and is the user's choice.

### 6.7 The network

See [spec/sandbox.md, Network rules](../spec/sandbox.md#network-rules) and
the [net-policy](../design/epoch-0/net-policy.md) proposal.

- **Modes.** `disable` masks `#I` and `#ℏ`. `outbound` (the default) refuses
  `announce` for TCP and UDP. `enable` allows it.
- **Without `--net-allow`**, connects anywhere but link-local (169.254.0.0/16
  and fe80::/10) are allowed, including the host's loopback and LAN.
- **With patterns**, a connect must match by protocol, address or CIDR or
  `*`, and port or range. A name pattern is enforced through `cs`, which
  resolves only covered names and records each answer in the machine's
  resolved-name table (the 1,024 most recent entries), against which later
  numeric connects are matched.
- **DNS.** For Linux roots without `/etc/resolv.conf`, h9 supplies the host's
  DNS servers, and port 53 on them is allowed even when they're link-local;
  `--print` says so.
- **Connections h9 makes itself** (roots, namespace-file mounts, static
  trees, credential helpers' targets) are outside the policy, and the guest
  can't reach them by name.
- **Host-side code**: devip's host socket layer in
  `src/kern/hostsock-{posix,win32,wasm}.c`, and the Linux socket layer in
  `src/kern/linuxnet.zig`.

### 6.8 9P, remote roots, and indexes

Every 9P connection h9 mounts, and every one a guest mounts through
`dotlfs`, goes through a `#ℓ` translator, and every mount from `--url` or a
namespace file also goes through a `#ι` index layer unless `--index none`.
These parse untrusted bytes in the h9 process (A2). See
[spec/ninep.md](../spec/ninep.md).

- **`src/dotl/wire.zig`** encodes and bounds-checks 9P2000, 9P2000.L, and
  9P2000.L.Z. `client.zig` and `server.zig` are state machines over bytes,
  tested against `testserver.zig` and fuzzed. Look at fid and tag
  allocation, the reconnect path (`Trebind`, replayed opens, resent
  mutations), `msize` up to 1 MiB, read-ahead, and the user map.
- **`src/rootindex/layer.zig`** sits between devmnt and the server, holds
  the first attach while it reads `.fs/index` and `.fs/events`, answers walks
  and stats locally, and uses fids from `0xF0000000` and tags from `0xFFFE`
  down to `0xF000`. `src/rootindex.zig` compiles index text (up to 256 MB)
  into a form checked by a SHA-256 trailer.
- **Static trees** (`src/statictree.zig`) are served by h9 over a unix
  socket in a private 0700 directory, with BLAKE3 checks for files that
  carry a hash, and links resolved inside the tree.
- **WebSockets and HTTP** (`src/hstream.zig`, `src/ws.zig`): TCP, TLS
  through `std.crypto.tls`, HTTP `CONNECT` proxies from the host's
  `HTTPS_PROXY`, `ca=` files, and framing.
- **Credential helpers** (`src/cred.zig`): host commands named in
  `--cred` and `$H9CRED`, run with the URL as an argument, with output
  parsed as header lines and zeroed after the handshake. Guest `/net/ws`
  conversations never run one.
- **The index cache** (`src/rootindex/cache.zig`): 0700 directory, 0600
  files, every read checked against its trailer.

### 6.9 Serving

`--serve` makes a machine a 9P server ([ninep.md, Serving](../spec/ninep.md#serving),
`src/serve.zig`):

- Unix listeners take a `flock` on `PATH.lock`, are made 0600, and won't
  replace a path that isn't a socket. TCP listeners set `SO_REUSEADDR`.
  `ws://` listeners check the path, method, upgrade version, `Origin`
  against `--serve-origin`, and the token (SHA-256 digests compared in
  constant time).
- Unix, TCP, and token-less WebSocket listeners have **no authentication**;
  `--print` lists each as a caveat.
- Each connection is an `exportfs -r ROOT` in the guest (`-R` under
  `--write=none`), behind a `#ℓ` server side, in a server Proc that forked
  the plan's namespace before the program ran and unmounted `/net` unless
  `--serve-net`. At most 32 connections and 8 processes per connection.

### 6.10 Console and graphics

- The console is `cons` and `consctl` only. `rawon` switches the host TTY to
  raw mode. There are no host ioctls.
- `--gfx` opens one host window with drawterm's GUI backends (Cocoa, Win32,
  or X11). `/dev/snarf` is the host clipboard unless `--gfx=noclip`. A guest
  with `--gfx` can read and write the host clipboard.

### 6.11 Resource exhaustion

`--memory` is exact for guest pages (1 GiB by default, at most 32 GiB).
`--pids`, `--cpus`, and `--timeout` are unlimited by default, so a fork bomb
runs into memory and host threads, not a process cap. Disk under writable
paths isn't capped. Host-side buffers outside guest memory (devip queues,
per-stream WebSocket queues of 16 MiB, the index cache, translator state)
are bounded per structure, not per machine; an audit may find unbounded
ones.

### 6.12 Several machines in one process

The CLI runs one machine per process, but the library, the test suite,
and (soon) child machines run several, sharing one drawterm kernel. Each
machine has its own Pgrp, Fgrp, Egrp, device mask, console, `/srv` board,
pid space, and union numbers. Some tables are shared on purpose: record
locks, FIFOs, the Linux page cache and shared-file table, System V shared
memory (per engine), semaphore wait lists (keyed by host address), and
devip's static conversation tables.

### 6.13 The web host

On wasm32-wasi ([spec/host-web.md](../spec/host-web.md)) every guest runs on
h86 or ha64 inside the wasm instance, in a Worker. `#C` and `#I` are always
masked and the network is WebSockets only. Under Node, `h9-node` preopens the
host's `/`, so the policy in h9's wasm code is the only thing between a
guest and the host's file system there; in a page, files come from an
in-memory archive.

## 7. Recent and pending changes

### 7.1 Narrow chroot (merged, #289)

[linux-chroot](../design/epoch-0/linux-chroot.md) lets a Linux process's `chroot(2)`
narrow its own root to a directory it can already reach, instead of
returning `EPERM`. The directory is walked as any Linux path, through the
policy, and kept in the process's record (`Hproc.lroot`, its chan marked
`CLROOT`); absolute paths, absolute link targets, and exec's program and
interpreter are found from it, and `..` at it stays there (`h9_fs_atroot`,
from `walkl` in `chan.c`). It can never widen past the Linux view, uid 0
grants nothing, and `mount`, `umount2`, `pivot_root`, `unshare`, and `setns`
stay refused. Code: `h9_linux_chroot`, `h9_linux_setslash`, and
`h9_linux_dotfd` in `src/kern/linux.c`, the `walkl` change in the vendored
`chan.c`, and `src/abi/linux/sys.zig`. Cases: `[linux-chroot]` in
`tests/integration.zig`.

Things to check: that no path (`..` through a link, a directory fd from
before the chroot, `/proc/self/cwd`, `/proc/self/fd/N`, a socket's switch to
the 9front view, exec, fork, or a pre-chroot working directory) gets a
process above the Linux view's top; and that chroot is not treated anywhere
as a boundary between processes of one machine (it isn't one on Linux
either, and a pre-chroot fd deliberately leads back to the Linux view's top).

### 7.2 Virtual loopback (draft, [PR #287](https://github.com/progrium/hyper9/pull/287))

The `virtual-loopback` proposal gives each machine its own loopback in
devip: announces and connects on 127.0.0.0/8 and `::1` stay in the kernel,
joined by `qio` queues, with no host socket. Its security effects:

- A guest no longer reaches the host's loopback services by default
  (databases, admin panels, other h9 processes' `--serve` listeners). It
  reaches them only through a reserved address, `host.h9.internal`
  (169.254.0.1), port by port with `--net-host`, which `--net-allow`
  patterns can't open.
- `outbound` allows loopback and wildcard announces, on the machine's
  loopback only. A new `--net=loopback` mode gives a loopback and nothing
  else; `disable` still masks `#I`.
- `--publish` makes h9 listen on a host port (loopback by default) and
  forward into the guest's loopback, with calls arriving from
  `host.h9.internal` so they don't get the trust a server gives loopback
  peers.
- New vendored branches in `devip.c`, calling a new `src/kern/loopback.c`.

An audit before it lands should review its design for the per-machine
table's isolation, the 169.254.0.1 rewrite (only that address, only to the
host's 127.0.0.1), the wildcard rules under each mode, and the narrowing
order `disable` < `loopback` < `outbound` < `enable`. An audit after it
lands should treat `src/kern/loopback.c` and the `devip.c` branches as in
scope.

### 7.3 File watching (draft, [PR #288](https://github.com/progrium/hyper9/pull/288))

The `file-watch` proposal adds a change journal per machine, fed by the
guest's own changes, by host watchers on `--dir` trees (inotify, FSEvents,
`ReadDirectoryChangesExW`, or polling), and by 9P servers' `.fs/events`. It
adds a device, `#ν` (`/dev/fsevents`), Linux inotify, union and overlay
filtering of members' changes, and later `.fs/events` under `--serve`. Its
Security section claims nothing new is reachable: a subscription reports
only names under a directory the subscriber could walk, host changes under
`--read-deny` or outside the access rules are dropped, host paths never
reach the guest, and watches, streams, and queues are bounded per machine.

New surface once it lands: host watcher threads that act on host-reported
paths (a race and path-mapping surface like A5's), event-record parsing from
9P servers (A2), a guest-visible change stream whose filtering through
unions and whiteouts must match what a walk would show, and inotify's syscall
and queue code in the Linux ABI.

### 7.4 Other drafts that change the sandbox

- [plan-format](../design/plan-format.md): the plan as a file, the one input,
  and narrowing (see 5).
- [host-sandbox](../design/host-sandbox.md): apply the policy to the h9
  process itself (Seatbelt, Landlock and seccomp, AppContainer). Not built.
- [hide-host-paths](../design/epoch-0/hide-host-paths.md): hide host paths in
  `/proc/n/ns` under the stricter profiles. Not built.
- [child-machines](../design/child-machines.md), [host-handles](../design/host-handles.md),
  [kernel-port](../design/kernel-port.md), and [host-cmd](../design/host-cmd.md)
  change where machines and host access come from.

`zig build design -- list` shows every proposal and its status.

## 8. Scope

### In scope

| Area | Paths |
| --- | --- |
| Policy, plan, and namespace | `src/policy.zig`, `src/newns.zig`, `src/mount.zig`, `src/machine.zig`, `src/cli.zig`, `src/main.zig`, `src/root.zig` |
| Guest memory and syscalls | `src/abi/plan9/syscall.zig`, `src/segment.zig`, `src/guestmem.zig`, `src/abi/plan9/aout.zig`, `src/abi/plan9/loader.zig`, `src/cpupool.zig`, `src/engine/hcpu/hcpu.zig`, `src/kern.zig` |
| Engines | `src/engine.zig`, `src/engine/{hvf,kvm,kvm_abi,whp,whp_abi,gphys,pt_arm64,pt_amd64,x86,arena,hcpu,h86,ha64,hx64}.zig` |
| Shims and register state | `src/arch/amd64/shim.S`, `src/arch/arm64/shim.S`, `src/arch/{amd64,arm64,i386}.zig` |
| Emulator CPUs | `src/engine/hcpu/interp/` (especially `mem.zig`), `src/engine/hcpu/jit/` (especially `codemem.zig`, `cache.zig`, `dispatch.zig`, the emitters' memory paths), `src/web/` for wasm |
| Linux ABI | `src/abi/linux/`, `src/kern/linux.c`, `src/kern/linuxnet.zig`, `src/kern/rconv.zig`, `src/kern/devlinux.c`, `src/kern/dev/pty.zig`, `src/kern/fifo.c` |
| h9's kernel code | `src/kern/*.c` and `*.h` (hooks, devices, process model) |
| Vendored kernel, as changed or reached | `third_party/drawterm/kern/` (devfs, devip, devmnt, chan, sysfile, qio, devpipe, devtls), and the libraries it calls from guest-reachable paths (`libsec`, `libip`, `libc`) |
| 9P, indexes, and streams | `src/dotl/`, `src/rootindex/`, `src/rootindex.zig`, `src/statictree.zig`, `src/hstream.zig`, `src/ws.zig`, `src/cred.zig` |
| Serving | `src/serve.zig` |
| Console and graphics | `src/consin.zig`, `src/stdin.zig`, `src/kern/devhcons.c`, `src/kern/consx.c`, `src/gfx.zig`, `src/kern/gfx*.c` |

### Out of scope, or informational

- `src/engine/sud*.zig` (not a boundary; findings are informational).
- Hypervisor and CPU bugs, and side channels.
- `third_party/drawterm` code not compiled into h9 or not reachable from a
  guest, and drawterm's GUI backends beyond the clipboard and input paths.
- Build tools, tests, and fixtures: `tools/`, `tests/`, `scripts/`,
  `build.zig`, `site/`.
- The 9front and Linux binaries in a root, and `src/9box/` and `src/guest/`
  (guest-side code that runs inside the sandbox).
- The sibling repositories (`h9reg`, `h9x`, `mkroot-9front`), which use h9
  but aren't part of its sandbox.
- Drafts not yet built (section 7), except as design review.

## 9. Hardening already done

Grouped by boundary, with where each is described.

- **B1, B2.** One guest-physical region mapped once, with pages handed out
  by h9's allocator; released ranges are given back to the host and fresh
  pages mapped over them ([engines.md](../spec/engines.md#the-engine-interface-engine)).
  SMEP and SMAP where the CPU has them, NX, and per-vCPU GDT and TSS with an
  IST stack on amd64. CPUID hides state FXSAVE can't carry. The shim holds no
  policy. `arch.sanitize` and `rt_sigreturn` restore only user-settable
  state. 9front's register-zeroing on syscall return is reproduced, so no
  host or kernel values leak into registers.
- **The emulator.** No host faults are relied on; every access is checked
  against arena memory the address space owns, and a TLB fill is the
  permission check. Code pages never get write TLB entries, with
  generation counts to close invalidation races. W^X code memory on every
  host. Fuzzers run each CPU in lockstep against Unicorn
  ([jit.md](../spec/jit.md)).
- **B3.** `GuestBuf` translation for every buffer, bounded copies of every
  string, and "bad address" on any unmapped byte. Semaphore words checked
  for alignment, mapping, and writability. Linux `fork` shoots down before a
  page can be reused.
- **B4.** Resolve-then-check on every devfs operation, with constant-cost
  resolution on Linux; name-based checks for create, remove, and rename on
  each host, including Windows' case, 8.3, and trailing-dot aliases; rename
  of a directory above a rule refused; contained trees resolved by h9;
  Linux walks that stop at links, with opens that refuse a link swapped in
  after the walk; `#U` masked after the namespace is built; `#ι` masked
  after `--ns`; `#C` never built.
- **B5.** Checks before any host socket is bound or dialed; name-based
  egress through `cs` and the resolved-name table; link-local refused by
  default; `#ℏ` connects checked as TCP dials; `--trace` never prints write
  data, so URLs and headers written to a `ctl` don't leak into traces.
- **B6.** One bounds-checked wire codec for every 9P dialect, fuzzed; a
  reply for an unknown tag fails the connection; index files checked by
  SHA-256 trailers in the cache; static-tree files checked by BLAKE3 where
  hashed; credential-helper output parsed as headers, merged under
  `header=`, zeroed after use, and warned about over `ws://`.
- **B7.** Listeners opened before the program runs; 0600 unix sockets with a
  lock file; constant-time token comparison; `Origin` checks; connection
  and per-connection process caps; `/net` unmounted from the server Proc by
  default.
- **B8.** devproc, devsrv, `#O`, `#ℏ`, and the console look everything up in
  the caller's machine.
- **The sud engine's audit (Nov 9, 2026).** The guest can write the
  stub's control page and jump into stub code, so the engine can't contain
  it; `auto` no longer selects it and `--engine sud` warns
  ([native-backend Updates](../design/epoch-0/native-backend.md#updates)).
- **Recent fixes with a security flavour:** linux-chroot narrowing only (#289),
  locked `getdents64` buffers (#284), and races in `F_DUPFD` and
  non-blocking pipe reads (#283).

## 10. Known gaps and accepted risks

1. **The h9 process isn't host-sandboxed.** drawterm's C kernel and h9's
   devices run with the host user's rights, so any memory-safety bug a guest
   or a server can reach is an escape. [host-sandbox](../design/host-sandbox.md)
   is the plan; macOS research shows Seatbelt works after `hv_vm_create`.
2. **drawterm's `validaddr` is a no-op.** `GuestBuf` is the only check, so
   any syscall path that reaches guest memory without it is a bug.
3. **The sud engine isn't a boundary.** Inherent to running guest code
   in h9's address space with address-keyed gates.
4. **TOCTOU against host processes.** Checks resolve and then act; a host
   process renaming paths concurrently can race them (except where an
   `openat2` or `O_NOFOLLOW` chain closes the window).
5. **Hardlinks** under writable paths can modify files outside them.
6. **No disk cap** on writable paths.
7. **Information disclosure.** `/proc/n/ns` shows the host paths of bound
   trees ([hide-host-paths](../design/epoch-0/hide-host-paths.md)); the user name is
   the host user's; `ls -l` shows host owners and modes; Linux netlink
   answers with the host's interfaces; `cpuinfo` and `sysstat` show the
   host's CPUs; on sud, CPUID shows the host's.
8. **The default network is wide.** `outbound` reaches the host's loopback
   and LAN; link-local is the only default refusal. virtual-loopback closes
   the loopback part. Link-local DNS servers are allowed on port 53.
9. **Unauthenticated serving.** Unix, TCP, and token-less WebSocket
   listeners trust anyone who can connect; TCP 9P roots are unencrypted.
10. **Defaults favour interactive use.** No default `--pids`, `--cpus`, or
    `--timeout` in the default profile.
11. **Shared state between machines in one process** (6.12) is by design,
    but each shared table is a place where one machine might affect
    another.
12. **The plan isn't yet a single input.** Flags, `Machine.Options`,
    `createMachine`, and a child's `ctl` are kept in step by hand until
    plan-format lands, so a policy field one front door lacks is a gap.
13. **The web host under Node** preopens `/`, so h9's wasm code is the only
    file-system boundary there.
14. **`--gfx`** shares the host clipboard unless `noclip`.

## 11. Suggested focus

In rough order of expected value:

1. **Guest memory handling in the kernel seam**: every place a guest
   address or length reaches C or Zig code (`src/abi/plan9/syscall.zig`,
   `src/abi/linux/sys.zig`, `GuestBuf`, `AddressSpace.translate` and `copy`,
   devproc's `mem`), including concurrent unmaps from other threads.
2. **The Linux ABI's memory manager** (`src/abi/linux/mm.zig`, shared
   chunks, copy-on-write, shootdowns, the page cache), for use-after-free
   across threads and forks.
3. **Untrusted 9P and index parsing** (`src/dotl/`, `src/rootindex/`,
   devmnt), as A2: malformed messages, tag and fid confusion, reconnect
   replay, oversized fields.
4. **devfs path checks** (`src/kern/fscheck.c`), as A1 and A5 together:
   links, `..`, contained trees, Windows path aliases, renames, and the
   overlay's copy-up and whiteout paths in `devoverlay.c`.
5. **The shims and CPU state** on KVM and HVF: what user mode can reach in
   the kernel half, exception paths with a malicious Ureg, the kick races.
6. **The emulator's JIT** memory checks and invalidation, since the emulator
   is the default fallback wherever there's no hypervisor.
7. **Net policy bypasses**: IPv4-mapped IPv6, unusual dial strings, UDP
   `sendto`, `cs` and the resolved-name table, `/net/ws`, Linux sockets on a
   mounted `/net`.
8. **Cross-machine isolation** in one process, including the shared tables.
9. **Design review** of virtual-loopback, file-watch, and plan-format before
   they land.

## 12. An audit plan

This is how we would run the audit if we were the auditors: the order of
work, the methods for each boundary, what each phase delivers, and how we'd
know we were done. It assumes two auditors for about six weeks, with access
to a macOS arm64 machine (HVF), a Linux x86\_64 machine with KVM on bare
metal, a Linux arm64 machine with KVM, and a Windows x86\_64 machine with WHP.
A smaller engagement keeps the phases and their order and cuts the depth of
phases 3 and 4.

### Ground rules

- **Pin a commit.** Audit one commit of `main` (see [Revision](#revision)),
  and diff anything that lands during the audit against it, so findings
  name a tree that exists.
- **Prove escapes, not just bugs.** For each boundary, set up a canary the
  guest must not reach, and count a finding as an escape only when a guest
  (or a server, for A2) reaches it. The canaries:
  - a host file outside every policy path, and one under `--read-deny`
    inside a bound tree, each holding a random token;
  - a read-only host file whose hash is checked after the run;
  - a TCP listener on the host's 127.0.0.1, one on a LAN address, and a
    fake metadata endpoint on 169.254.169.254 (in a network namespace or
    VM), each logging any connection;
  - a host environment variable holding a token;
  - a second machine in the same process (through the embedding API or
    `tests/engines.zig`'s harness) holding its own token in `/tmp` and
    `/srv`;
  - for code execution in h9, a host file h9 would have to create
    (`/tmp/pwned`) that no guest path maps to.
- **Write every finding as a test.** A proof of concept is a guest program
  or rc script plus the h9 flags, written so it can become an integration
  case tagged with the proposal it breaks, as h9's own cases are
  ([spec/testing.md](../spec/testing.md)).
- **Severity by what's reached**, highest first: code execution in the h9
  process; reading or writing a host file outside the plan; reaching a
  network destination the plan refuses; crossing between machines; denial
  of service of the host beyond the plan's limits; information disclosure.
  A bug that needs a malicious server (A2) or a racing host process (A5)
  is rated by what it reaches, with the precondition stated.

### Phase 0: set up (days 1 to 3)

1. Build h9 on each host in Debug and ReleaseSafe, fetch the roots, and run
   `zig build test`, `zig build integration`, and `zig build proposal
   -Dp=baseline` on every engine, so failures later are ours and not the
   environment's. Record `h9 --check` on each host.
2. Build an instrumented h9 on Linux x86\_64: check whether the C kernel is
   already built with UBSan (Zig enables C's undefined-behaviour checks in
   Debug), and add AddressSanitizer for `src/kern/` and
   `third_party/drawterm/kern/` where the toolchain allows it. Run the
   integration suite under it once as a baseline.
3. Write the canary harness above as a script that runs a guest command
   under given flags and reports which canaries it reached, and add the
   `--print` output for each profile under test to the audit's notes.
4. Walk through sections 1 to 6 of this brief with the maintainer, and
   agree the threat model, the severity scale, and how to report a
   critical finding mid-audit.

**Delivers:** working builds on each host, the canary harness, and the
agreed threat model.

### Phase 1: map and model (week 1)

1. **Read the seam.** Trace a syscall end to end on each engine: the
   shim's entry, the exit, `src/machine.zig`'s loop, `src/abi/plan9/syscall.zig` or
   `src/abi/linux/sys.zig`, `GuestBuf`, the `sys*` wrapper in `sysfile.c`, the
   device, and back. Note every place a guest value becomes a host pointer,
   a length, an index, or a path.
2. **Enumerate guest-reachable entry points**: the 9front syscall table,
   the Linux table in `src/abi/linux/nr.zig` (marking each call as served,
   refused, or `ENOSYS`), every device's walk, open, read, write, and wstat,
   every `ctl` message (`#ℓ`, `#ℏ`, `#O`'s clone, devproc, devip), and every
   ioctl the Linux layer serves.
3. **Enumerate host-side inputs** from A2 and A3: every 9P message type each
   side of `src/dotl/` parses, index and event records, HTTP responses and
   WebSocket frames, and the listeners' request parsing.
4. **Grep for patterns** that need a look wherever they appear: `@ptrFromInt`,
   `@intCast` and `@truncate` on guest values, slices built from guest
   lengths, `memcpy` and `memmove` in C, `waserror` near Zig frames (seam
   rule 1), `validaddr`, and locks dropped around host calls.
5. **Turn sections 4 and 6 into a threat model per boundary**, as attack
   trees from each adversary to each canary.

**Delivers:** the entry-point inventory and the attack trees, which drive
phases 2 to 4.

### Phase 2: the policy as specified (week 2)

Test what the spec promises before hunting for memory bugs, since a logic
bypass is cheaper to find and as severe.

- **File system (B4).** For each profile and `--write` mode, try to reach
  the file canaries: `..` past a bind and a contained tree's top; absolute
  and relative symlinks, link loops, and links swapped in by a host process
  between walk and open (a loop of `rename(2)` on the host while the guest
  walks); hardlinks inside a writable path; rename of a directory above a
  rule; the overlay's copy-up, whiteout, and rename paths; Linux `chroot`
  followed by `..`, `fchdir`, `/proc/self/fd/N`, and exec; and on Windows,
  case, 8.3 names, trailing dots and spaces, alternate data streams,
  junctions, and UNC and device paths. Repeat each through a 9front
  program and a Linux program, since their walks differ.
- **Devices (B4, B8).** Try to attach every masked device by every
  spelling (`#U`, `#U!c`, `#I0`, a `#` path through a bind, a namespace file
  replayed by the guest's own `newns`), and to reach another machine's
  union numbers, `/srv` posts, pids, and `#ℏ` conversations.
- **Network (B5).** For each `--net` mode and a set of `--net-allow`
  patterns, try to reach the network canaries: IPv4-mapped and other IPv6
  spellings of v4 addresses, decimal and octal address forms, `0.0.0.0`,
  broadcast, dial strings with odd separators or empty fields, UDP `sendto`
  to an unconnected address, Linux sockets on a mounted `/net`, `cs` with a
  name that resolves to a refused address, the resolved-name table after it
  evicts, `/net/ws` with a URL whose host differs from its `Host` header,
  and link-local DNS servers on ports other than 53.
- **Environment, identity, and limits.** Check that no host variable reaches
  the guest by any path (`/env`, `/proc`, a Linux `envp`, `#c`), and that
  `--memory`, `--pids`, `--cpus`, and `--timeout` hold under fork bombs,
  thread bombs, overlay writes, page-cache fills, and stuck host calls.
- **The plan.** Check that `--print` matches what's enforced for every
  profile and flag combination we test, and that every line `--print`
  writes replays through `--ns` to the same namespace.

**Delivers:** findings against the policy, and a table of each promise in
section 2 with the cases that test it.

### Phase 3: memory safety at the seam (weeks 3 and 4)

- **Syscall fuzzing from inside the guest.** Build a guest-side fuzzer, a
  static Linux program and a 9front program, that makes random and
  structure-aware calls (valid fds and paths from a pool, buffers that
  straddle unmapped pages, lengths near powers of two and 2³¹, pointers into
  text, and concurrent `munmap`, `mprotect`, and `mremap` from other
  threads during blocking calls). Run it under the instrumented h9 on KVM
  and the emulator, with the canary harness watching, for days. Syzkaller's
  Linux descriptions are a good source of argument shapes.
- **Differential testing.** Run the Linux fixtures and the fuzzer's corpus
  under h9 and under a real Linux kernel, and 9front programs under h9 and
  under 9front in QEMU, and look at where results differ around memory,
  signals, and errors: a difference there is often a missing check.
- **Manual review**, in the order of section 11: `GuestBuf` and every caller
  that bypasses it; `src/abi/linux/mm.zig`'s chunk reference counts, copy-on-write
  and shootdown ordering; `src/abi/linux/signal.zig`'s frames and
  `rt_sigreturn`; `src/kern/devoverlay.c`'s allocator and node lifetimes;
  devproc's `mem` and `regs` against a running target; and the
  `src/cpupool.zig` handoff.
- **The shims and CPU state.** On KVM and HVF, write user-mode probes that
  try to read and write the kernel half, the doorbell, and the per-vCPU
  shared page; that fault inside the shim's paths (a bad stack, a
  non-canonical return address, a pending trap flag); and that race a kick
  against a syscall. Read the CPU state the host sets (`src/engine/x86.zig`,
  `pt_amd64.zig`, `pt_arm64.zig`) against the architecture manuals for
  anything user mode can change or see.
- **The emulator.** Extend the existing lockstep fuzzers toward memory:
  accesses that cross pages and regions, self-modifying code across
  threads, and stores into code pages racing their execution, with the
  arena's neighbours as canaries.

**Delivers:** memory-safety findings with proofs of concept, and the
fuzzer, its corpus, and its harness, handed over so h9 can keep running
them.

### Phase 4: hostile servers and clients (week 5)

- **A malicious 9P server.** Write a server that speaks 9P2000, 9P2000.L,
  and 9P2000.L.Z and misbehaves on purpose: wrong tags and fids, replies to
  requests never sent, oversized counts and strings, directory entries that
  don't parse, symlink targets that climb or loop, a `9P-Uid` and
  `9P-User` that collide, `Rlerror` with odd errnos, disconnects at every
  step of a reconnect, and `Trebind` replies that disagree. Mount it as a
  root, as a namespace-file mount, and from inside the guest with
  `dotlfs`, and fuzz `src/dotl/` and `src/rootindex/` with it under ASan.
- **Indexes, events, and static trees.** Fuzz index text and compiled cache
  files (a tampered cache entry with a valid-looking trailer), event
  streams, and static-tree responses (wrong lengths, `Range` replies that
  overlap, hashes that don't match, redirects).
- **Streams and helpers.** Fuzz the WebSocket client and server framing and
  the HTTP handshake parsing in `src/ws.zig` and `src/hstream.zig`, proxy
  responses, and credential-helper output.
- **Serving.** Attack each `--serve` listener as A3: authentication and
  `Origin` checks, slow and half-open connections against the 32-connection
  and 8-process caps, and requests through `src/dotl/server.zig` that try
  to leave `--serve-root`.

**Delivers:** findings against A2 and A3, and the hostile server, kept as a
test fixture.

### Phase 5: design review, retest, and report (week 6)

1. Review the drafts that change the sandbox (virtual-loopback, file-watch,
   plan-format, host-sandbox, and linux-dns) against the threat model, and
   write what each should test before it lands.
2. Retest every fix the maintainer made during the audit, on every engine
   it touches.
3. Write the report: a summary for a reader who won't read the rest; each
   finding with its boundary, adversary, severity, preconditions, proof of
   concept, root cause, and a suggested fix; the promises in section 2 with
   what was tested against each and what wasn't; and the residual risks,
   including the known gaps in section 10 we agree with and any we'd rate
   higher.
4. Hand over the canary harness, the fuzzers and their corpora, the hostile
   server, and the proofs of concept as integration cases.

### What we'd leave out, and say so

The hypervisors and CPUs themselves, side channels, the sud engine
beyond confirming its documented status, guest binaries in the root, the
sibling repositories, and the web host beyond a review of the Worker's
message handling and h9-node's preopen. The report would list each
exclusion so a later audit can pick it up.

### How we'd know we were done

- Every promise in section 2 has at least one case that would fail if it
  broke, run on every engine that's a boundary.
- Every entry point in the phase 1 inventory has been fuzzed, reviewed, or
  listed as not covered, with a reason.
- The guest fuzzer and the hostile server have run for an agreed time with
  no new crash, under the instrumented build.
- Every critical and high finding is fixed and retested, or accepted in
  writing by the maintainer.

## 13. Building, running, and testing

[DEVELOPING.md](../DEVELOPING.md) is the full guide. In short, with Zig
0.16.x:

```sh
. scripts/env.sh           # caches and tools in .local/; puts zig-out/bin on PATH
./scripts/fetch.sh         # pinned 9front source and image, Alpine roots, and test dependencies
zig build                  # zig-out/bin/h9 (ad-hoc signed with h9.entitlements on macOS)
zig build mkroot           # the 9front root tree in .local/9front/root (needs QEMU)
h9 --check                 # which engines work here, and the vCPU limit
```

Host requirements: macOS arm64 with Xcode (HVF; the binary needs the
`com.apple.security.hypervisor` entitlement); Linux with read and write on
`/dev/kvm` (KVM), or any Linux x86\_64 for hcpu and sud; Windows
x86\_64 with the Windows Hypervisor Platform feature (WHP). Without a
hypervisor, `auto` uses the emulator, so every check below runs anywhere,
slower. `scripts/lima/` sets up Linux test VMs from a Mac.

**Inspecting a sandbox:**

```sh
h9 --print [flags] PROGRAM          # the compiled plan: profile, enforces, devmask, namespace, access, caveats
h9 --trace [flags] PROGRAM          # every syscall with arguments, result, and error, and faults with the Ureg
h9 --profile=tight --rc 'cat /proc/$pid/ns'
h9 --engine hcpu|kvm|hvf|whp ...    # force an engine
```

**Tests:**

```sh
zig build test                       # unit tests, and the engine cases on every engine built in
zig build integration                # real binaries through the CLI (needs the root tree)
zig build integration -Darch=amd64   # amd64 cases on KVM and the emulator
zig build integration -Dweb          # the same cases through h9-node on h86
zig build proposal -Dp=baseline      # one proposal's demos and cases, by slug (also net-policy, linux-chroot, symlinks-in-root, ...)
zig build linux-fixtures             # the static musl programs the Linux cases run
zig build design -- check            # the design docs, test tags, and links
```

Integration cases are tagged with the proposal they prove, so a boundary's
cases can be run by slug. The ones most relevant to the sandbox:

| Tag | What the cases cover |
| --- | --- |
| `baseline` | `--sandbox`, `--read-deny` with symlinks and `..`, masked devices |
| `net-policy` | `outbound`, `enable`, link-local, `--net-allow` by CIDR and name, `cs` |
| `ephemeral-writes`, `overlay` | Writes in memory, `--read-deny` inside an ephemeral tree |
| `symlinks-in-root` | Contained trees: absolute links, `..`, loops, deny rules |
| `linux-symlinks` | Linux walks that stop at links, links to unseen host paths |
| `linux-chroot` | chroot narrowing, `..`, fds from before, refused calls |
| `websocket-9p` | `/net/ws` under each mode |
| `guest-tools`, `gfx` | `#H` and graphics devices masked |
| `native-backend` (in `tests/engines.zig`) | Every AX value traps; a jump into the stub can't open a host file |

`tests/engines.zig` also has the memory-cap, fault, kick, note, and
register-zeroing cases on every engine built in. The fuzzers for the
emulator CPUs and the 9P codec are built by `zig build` targets described
in [spec/jit.md](../spec/jit.md#testing) and `build.zig`.

CI ([.github/workflows/ci.yml](../.github/workflows/ci.yml)) runs the design
check on every PR, and the unit and integration tests on PRs from proposal
branches.

## 14. Reference map

| For | Read |
| --- | --- |
| The whole system | [SPEC.md](../SPEC.md) |
| Security stance, policy, access rules, `--print` | [spec/sandbox.md](../spec/sandbox.md) |
| Engines and shims | [spec/engines.md](../spec/engines.md) |
| Kernel, process model, seam rules | [spec/kernel.md](../spec/kernel.md) |
| 9front ABI | [spec/abi-plan9.md](../spec/abi-plan9.md) |
| Linux ABI | [spec/abi-linux.md](../spec/abi-linux.md) |
| Mounts, 9P dialects, indexes, serving | [spec/ninep.md](../spec/ninep.md) |
| Boot sequence and device mask | [spec/machine.md](../spec/machine.md) |
| CLI flags and exit codes | [spec/cli.md](../spec/cli.md) |
| Web host | [spec/host-web.md](../spec/host-web.md) |
| Namespace kernel | [spec/nskernel.md](../spec/nskernel.md) |
| Emulator CPUs | [spec/jit.md](../spec/jit.md), [spec/h86.md](../spec/h86.md), [spec/hx64.md](../spec/hx64.md), [spec/ha64.md](../spec/ha64.md) |
| User-facing sandbox docs | [MANUAL.md, chapter 23](../MANUAL.md#23-sandboxing), [docs/comparison.md](comparison.md) |
| Proposals and their status | [design/README.md](../design/README.md), [design/STATUS.md](../design/STATUS.md) |

## Revision

Written against `main` at c0f71ec (Nov 24, 2026), after linux-chroot
(#289), with virtual-loopback (#287) and file-watch (#288) still drafts.
Update this brief when a change crosses a boundary in section 4, and give
the auditor the commit it describes.

Updated for [renames](../design/epoch-0/renames.md), which changed names and nothing
else ([design/README.md](../design/README.md#old-names) has the table of old
names): the ABIs are in `src/abi/plan9/` and `src/abi/linux/`, the engines in
`src/engine.zig` and `src/engine/`, with hcpu's CPUs and JIT under
`src/engine/hcpu/`, and the web host and the namespace kernel are described in
[spec/host-web.md](../spec/host-web.md) and
[spec/nskernel.md](../spec/nskernel.md). The CLI's old spellings stay
accepted as aliases for one release, and `auto` never selects the sud engine
by either of its names.
