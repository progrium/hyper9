---
slug: host-sandbox
title: Host self-sandboxing
status: draft
created: 2026-11-03
authors: [progrium]
depends: [kvm, whp, hcpu, host-handles]
areas: [sandbox, engine, cli, tests]
branch: []
---

# Proposal: host self-sandboxing

## Abstract

Once a machine is set up, h9 confines its own process with the host's sandbox: Seatbelt on macOS, Landlock and seccomp on Linux, and process mitigation policies on Windows. It's applied after the backend, the JIT's code cache, the root, and the host handles ([host-handles](host-handles.md)) exist, and before the first guest instruction runs, so the host sandbox only has to allow what a running machine does, which is use what it already holds. Files are reachable only beneath the handles' directories, no new executable memory can be made (the code cache is already mapped), no host program can be started, and the network is reachable only when the plan or h9's own connections need it. Host commands, credential helpers, and the native backend's stubs are started by a small launcher process forked before the sandbox, which runs only what the plan lists. `--host-sandbox auto|require|off` controls it, and `auto`, the default, applies every layer the host has. This is defence in depth: the policy is still enforced by h9's kernel and its handles, and the host sandbox limits what a guest that took over the h9 process could do.

## Background

This was planned for after milestone M10 in SPEC.md, before milestones became proposals ([#1](epoch-0/proposals.md)). The research note below is SPEC.md's "Host self-sandboxing (future)" section as it stood there.

The guest is contained, but the h9 process runs drawterm's C kernel with the host user's full rights, and drawterm's `validaddr` is a no-op, so h9's own guest-address translation is the memory-safety boundary. Running h9 under gVisor doesn't work, because gVisor can't pass `/dev/kvm` through. Since the note was written, two things have changed what a host sandbox has to allow and how easily it can be derived:

- **The emulator is hcpu, and it generates code in h9's process.** [hcpu](epoch-0/hcpu.md) replaced Unicorn as the only emulator, built into every `h9`. Its JIT, T1, compiles guest code into a code cache that h9 runs directly, so on the `emu` backend there's no hardware boundary at all between guest code and h9: a lifter or emitter bug that lets guest code steer the generated code is code execution in h9. The cache is one `codemem.Region` per backend, 64 MiB by default (`H9_EMU_CACHE`), mapped once when the backend is created (`src/vmm/hcpu.zig`) and reset, never remapped, when it's full. Its mapping differs per host (`src/jit/codemem.zig`): one `MAP_JIT` mapping on macOS, with writes switched per thread by `pthread_jit_write_protect_np` on arm64; a memfd mapped twice, read-write and read-execute, on Linux (one RWX mapping only under a binary translator that misses writes through the other view); and a pagefile-backed section mapped twice on Windows. Where none of that is possible, the backend runs T0 with the same results.
- **The native backend is a known hole.** [native-backend](epoch-0/native-backend.md) records that a guest on `--backend native` can obtain code execution in the h9 process, since guest code runs in a stub that shares h9's RAM memfd and the gates are keyed by address. That's why `auto` never picks it. A host sandbox is what would contain such a guest.
- **[host-handles](host-handles.md) opens everything up front.** The kernel reaches the host only through a table of handles opened when the machine is made: directory handles, a dialer, a listener, the clock, the console, entropy, and the window. Native hosts open files beneath a directory handle, and the OS confines the result. Before handles, devfs opened host paths by name whenever the guest walked to them, and the policy was checks hooked in front of those opens, so a host sandbox would have had to allow every path the access rules might allow, including the ancestors devfs walks through.
- **h9 still starts host processes and makes its own connections.** [host-cmd](host-cmd.md) runs host commands the plan allows, [credential-helpers](epoch-0/credential-helpers.md) runs helpers for the WebSocket handshakes and static-tree fetches h9 makes, the native backend starts a stub process (`execveat` of a memfd image, through `clone` with `CLONE_VM|CLONE_VFORK`) for each address space on its first run, and a `--url` root, a static tree, and the index cache can all be reached after startup.

Each backend proposal records a research note so this could be built later:

- **macOS (done, below):** whether `sandbox_init` with a generated SBPL profile can be applied after `hv_vm_create` and still allow HVF calls, and which profile rules that needs.
- **macOS, [gfx](epoch-0/gfx.md):** which Mach and WindowServer lookups `--gfx` needs under Seatbelt.
- **Linux, [kvm](epoch-0/kvm.md):** Landlock for paths and TCP ports plus seccomp, with `/dev/kvm` already open; the syscalls `KVM_RUN` and vCPU threads need; the Landlock ABI each target distro ships. Known from the documentation, and untested: Landlock checks a device's ioctl rights when it's opened, and vCPU fds come from an ioctl rather than a path, so creating vCPUs after the sandbox is applied isn't blocked. seccomp needs `ioctl` (filtered by request number where possible), `mmap` of vCPU fds, and `tgkill` for kicks.
- **Windows, [whp](epoch-0/whp.md):** whether an AppContainer or restricted token can still use WHP.

**Research note: Seatbelt with HVF.** Tested on macOS 15.8.1 on an M3 Max with a small C program, ad-hoc signed with the hypervisor entitlement. It calls `hv_vm_create` and `hv_vm_map` on 16 MiB of guest RAM, then applies a profile with `sandbox_init_with_parameters`. That call is exported from libsystem_sandbox but not declared in `<sandbox.h>`, so it needs its own prototype. The profile was:

```scheme
(version 1)
(deny default)
(allow file-read* (subpath (param "ALLOWED")))
```

After that it creates a vCPU on each of two new pthreads, runs them to an `hvc #0`, maps and unmaps a second region, and opens files. Everything HVF worked under `(deny default)` with no other rules: `hv_vcpu_create` on new threads, `hv_vcpu_run` (exit reason exception, syndrome `0x5a000000`), `hv_vm_map`/`hv_vm_unmap` of new memory, and `hv_vm_destroy`. Thread creation needed no rule either. HVF needs no `iokit-open` or `mach-lookup` rule, because the VM and vCPUs are reached through the process's existing hypervisor handle, which is allowed by the entitlement rather than by the sandbox. Applying the same profile *before* `hv_vm_create` also worked, so ordering isn't forced by HVF. File rules behaved as expected, with one catch: `ALLOWED` must be the resolved path (`/private/var/...`, not `/var/...`), because the sandbox matches resolved paths. Reads inside it worked, writes there and reads elsewhere (`/etc/hosts`) failed with EPERM, and the process kept running. `sandbox_init*` fails with EPERM when the process is already sandboxed.

## Proposal

### When it's applied

The host sandbox is applied once per process, by the CLI, at the end of setup:

1. The plan is compiled, as now.
2. The backend is created: the VM on HVF, KVM, or WHP, the RAM, and on `emu` the arena and the code cache, after `codemem`'s probe has decided between T1 and T0.
3. The root and mounts are set up: `--url` roots dialled, archives unpacked, and indexes loaded.
4. The host handles are opened ([host-handles](host-handles.md)), along with h9's own: the index cache directory, `--trace`'s file, and `--serve`'s listeners, which are bound now.
5. If the plan needs it, the launcher is forked ([The launcher](#the-launcher)).
6. On Linux with glibc, one name lookup is made, so the resolver has loaded its NSS modules before executable mappings are refused.
7. The host sandbox is applied, in `src/host/sandbox.zig`, with one implementation per OS beside host-handles' `src/host/posix` and `src/host/win32`.
8. The first guest instruction runs.

vCPUs are still created after this, as programs start threads, and so are child machines ([child-machines](child-machines.md)), which share the parent's backend and its code cache. Neither needs anything the sandbox refuses.

It's compiled from the plan and the handles, not from the flags. Each rule names something h9 already holds, so the host sandbox can't allow more than the plan, and a rule that the plan needs but the host can't express is left to the handles, which already enforce it.

### What a running machine may do

| Area | Allowed after the sandbox | macOS | Linux | Windows |
| --- | --- | --- | --- | --- |
| Files | Beneath each directory handle, read-only or read-write as the handle is; h9's own handles; nothing else by path | `file-read*` and `file-write*` on each handle's resolved path | A Landlock rule per handle, made from the handle's own fd | Left to the handles |
| Executable memory | The code cache, already mapped. No new executable mapping, and no mapping made executable | No `dynamic-code-generation` rule | seccomp refuses `PROT_EXEC` in `mmap`, `mprotect`, and `pkey_mprotect`, and refuses `memfd_create` with `MFD_EXEC` | Arbitrary code guard (`ProcessDynamicCodePolicy`) |
| Host programs | None; the launcher starts them | No `process-exec` or `process-fork` rule | seccomp refuses `execve` and `execveat`, and `clone`, `clone3`, `fork`, and `vfork` without the thread flags | `ProcessChildProcessPolicy`, unless the launcher is needed |
| Network | Outbound when the plan allows any network or h9 has its own connections to make; listening only under `--net=enable` | `network-outbound`, `network-bind`, and the resolver's lookups, by the same rule | `socket` allowed by the same rule; Landlock's TCP connect and bind rights by port where the plan names only ports (ABI 4) | Left to the handles |
| Hypervisor | vCPU creation and runs, and RAM mapping, on the VM that exists | Nothing to add ([research note](#background)) | `ioctl` by KVM's request numbers on the VM and vCPU fds, and `mmap` of vCPU fds | WHP's calls, which go through the existing partition handle |
| Threads, time, and signals | As now | Nothing to add | `clone` with the thread flags, `futex`, `tgkill` to h9's own process, and the clock calls; Landlock's signal scope (ABI 6) | As now |
| The terminal | The console handle, already open | Nothing to add | Terminal ioctls on the console's fds | As now |

Anything else a running machine needs is a bug in this table, found by the test suite running under `--host-sandbox=require`.

### macOS

The profile is `(deny default)` with the rules above, generated as SBPL and applied with `sandbox_init_with_parameters`, as the research note did. Each handle's path is the resolved path the handle was opened at (`F_GETPATH`), so the rule and the handle agree on `/private/var`. The JIT should need no rule: the code cache is a `MAP_JIT` mapping made before the sandbox, and switching writes on and off for a thread with `pthread_jit_write_protect_np` changes per-thread CPU state, not the mapping. With no `dynamic-code-generation` rule, a second `MAP_JIT` mapping is refused. Both are for the research note to confirm, as HVF's rules were. `--gfx` adds the Mach and WindowServer lookups its research note finds.

### Linux

Landlock confines files, and seccomp confines everything else. They're applied in that order, after `PR_SET_NO_NEW_PRIVS`, to every thread h9 has. seccomp does that with `SECCOMP_FILTER_FLAG_TSYNC`. Landlock binds the calling thread and the threads it starts later, so the host threads already running (drawterm's kernel processes, and the run-slot pool's) apply the same ruleset too: through Landlock's thread sync where the kernel has it, and otherwise each in turn, at a point h9 asks them to reach before any guest code runs.

**Landlock.** The ruleset handles every file system right the kernel's ABI knows. Each directory handle becomes a `LANDLOCK_RULE_PATH_BENEATH` rule made from the handle's fd, so the rule is the directory the handle holds, with no path to resolve and nothing to race. A read-only handle gets the read rights and a read-write one all of them. `/dev/kvm` and the console are already open and need no rule. Network rights (ABI 4) and scopes (ABI 6) are used where the kernel has them. Landlock can't carve a denied path out of an allowed tree, and doesn't need to: read-deny patterns stay a check beneath the handle, as host-handles has it.

**seccomp.** An allowlist, compiled per plan and backend. The default action is `SECCOMP_RET_ERRNO(EPERM)`, so a call nobody expected fails the way Landlock's refusals do and the guest sees an error, not a dead machine. Calls that only an attack makes kill the process: `execve`, `execveat`, `ptrace`, `process_vm_writev`, and an `mmap`, `mprotect`, or `pkey_mprotect` with `PROT_EXEC`. `PROT_EXEC` is checked by argument, which seccomp can do since `prot` is a value. The arena's frees (`mmap` over a range with fresh zero pages), HVF-style RAM mapping, and KVM's `kvm_run` mapping are read-write and stay allowed.

On a kernel without Landlock, or inside a container whose own seccomp profile refuses `landlock_create_ruleset`, files are left to the handles and only seccomp applies. Without seccomp, only Landlock does.

### Windows

Process mitigation policies, set with `SetProcessMitigationPolicy`: arbitrary code guard (no new executable memory; the code cache's two views of its section are already mapped), no child processes unless the launcher is needed, no remote or low-integrity image loads, and, without `--gfx`, win32k system calls disabled. Files and the network are left to the handles. An AppContainer or a restricted token, which would also confine files, isn't part of this ([Open issues](#open-issues)).

### The launcher

When the plan has host commands ([host-cmd](host-cmd.md)) or credential helpers ([credential-helpers](epoch-0/credential-helpers.md)), or the backend is `native`, h9 forks a launcher before applying the sandbox (on Windows, starts one). It isn't sandboxed by h9's host sandbox, and it's the one way h9 starts a host process afterwards. It's given the list of what it may run when it's forked, and takes requests over a socket pair:

- **Run host command N** with these arguments, stdin, stdout, and stderr. N indexes the plan's command list; the launcher never runs a path h9 names. The child gets a host sandbox of its own, compiled from the same plan with exec rights for its program, before it `exec`s (Seatbelt in the child after `fork`; Landlock and seccomp likewise on Linux), so a host command reaches what the guest could, as host-cmd intended.
- **Run credential helper N** for a URL. Helpers run without a sandbox, since they need the user's keychain or credential store, as they do now.
- **Start a stub** for the native backend, with the RAM memfd it inherited and a control memfd h9 passes over the socket. The stub image is fixed, and the stub installs its own seccomp filter, as now. h9 then needs neither `execveat` nor executable memfds.

A request the launcher can't match to its list fails, and the launcher exits with h9.

### CLI and API

- **`--host-sandbox auto|require|off`.** `auto`, the default, applies every layer the host has and carries on without the ones it lacks. `require` fails with exit 125 if any layer this host should have is missing: Seatbelt on macOS, Landlock and seccomp on Linux, or the mitigation policies on Windows, or if the process is already sandboxed by someone else (`sandbox_init` returning EPERM). `off` applies none, for debugging.
- **`--print`** lists a `host.sandbox` capability with the layers that would apply and the rules each would get.
- **`--check`** reports which layers the host has, and the Landlock ABI.
- **Embedders.** Applying the host sandbox is irreversible and process-wide, so `Machine` never does it alone. `h9.host.sandbox.apply(plan, handles)` is public, for an embedder that has made every machine it will make.
- **The web host** has no host sandbox: the browser is one.

## Rationale

**Why after setup, not before.** HVF allows either order, but setup opens the root, the handles, `/dev/kvm`, and the code cache, dials `--url` roots, and maps executable memory. A sandbox applied before all that would have to allow it all for the life of the machine. Applied after, it only has to allow using what's held, and a rule for executable memory can be "none".

**Why it depends on host-handles.** Before handles, devfs opened host paths by name whenever the guest walked to them, through ancestors that can be walked but not changed, with read-deny holes in allowed trees. Landlock can't say "walk but don't list", or "everything here but that", and Seatbelt's rules would race the checks in front of them. With handles, every directory h9 will open beneath is known when the sandbox is applied, Landlock's rule is made from the handle's fd itself, and what Landlock can't express is enforced by the handle, which is enforced anyway. The host sandbox only has to be coarser than the handles, never as fine.

**Why refuse new executable memory, not allow the JIT more.** The code cache is a fixed size, mapped once, and reset when full, so a running JIT never asks for more. Refusing `PROT_EXEC` after setup costs nothing and removes the easiest second stage of any exploit of h9, which on `emu` is the code the JIT runs for the guest. It holds on every host: seccomp by argument on Linux, no `dynamic-code-generation` on macOS, and arbitrary code guard on Windows.

**Why a launcher, not exec rights.** Allowing `execve` would let a compromised h9 run anything Landlock lets it read, and Landlock's execute right can't name only the plan's commands without also allowing their interpreters and libraries. Credential helpers need to run outside any sandbox, and the native backend's stubs need executable memory. A process forked before the sandbox, holding a fixed list, gives each of them what it needs and gives h9 nothing new: an index into a list.

**Why seccomp's default is an error, not a kill.** libc and the Zig standard library make calls the allowlist may not foresee on some kernel or distribution, and killing h9 on one loses the machine's output. EPERM degrades the way a refused open does. The calls that kill are the ones that never happen in a working machine.

**Why `auto` by default.** For a guest the policy allows, nothing changes: h9 uses what it holds, and the test suite proves it. A host without some layer still runs, and `--print` says what applied. `require` is for people who'd rather not run than run unconfined.

**Why not gVisor, or a separate kernel process.** gVisor can't pass `/dev/kvm` through, and on `emu` the guest's code runs in the process that would need confining anyway. Splitting the kernel into a sandboxed process with a broker beside it is a bigger change to every host call; the launcher is the smallest broker that covers what h9 starts.

**Why not an AppContainer on Windows yet.** An AppContainer reaches a file only if its directory's ACL names the container, which means changing ACLs on the user's files, and it's unknown whether WHP works inside one. The mitigation policies need neither, and handles already confine files.

## Compatibility

- **CLI.** `--host-sandbox` is new. Exit 125 under `require` when a layer is missing. The default changes no exit codes for a guest the policy allows.
- **`--print`.** A new `host.sandbox` line.
- **`Machine.Options`.** Unchanged. The public apply function is new.
- **Renaming a handle's directory on the host while a machine runs.** A handle follows its directory, but a Seatbelt rule names its path, so on macOS the guest loses access to a tree renamed under it. Landlock's rules follow the fd, as handles do.
- **Host commands.** They run under a sandbox compiled from the plan, where [host-cmd](host-cmd.md) runs them with the user's rights. A command that reads outside the plan fails, which is the point of the policy, and the plan's `--print` says so.
- **Debugging.** A debugger attaching to h9 from outside isn't affected. A debugger h9 would start, or a core-dump helper, is, and `--host-sandbox=off` is for that.
- **Tests.** The test runner makes many machines in one process, so it never applies the host sandbox to itself. Cases that need it run h9 as a child process.
- **`third_party/`.** Unchanged.

## Security

The guest can reach nothing new. What changes is what an attacker who has taken over the h9 process can do: through a hypervisor escape into h9, a bug in drawterm's kernel or h9's address translation, a lifter or emitter bug in hcpu's JIT, or the native backend's known hole. Without this, they have the host user's full rights. With it, they have the plan's files, the network the plan or h9 needs, the VM they're already in, and no way to make executable memory or start a process.

What's left:

- **The code cache's writable view.** On Linux and Windows the cache is mapped twice, and an attacker who can write anywhere in h9 can write code into the read-write view and run it from the other. They still can't make more executable memory, and the code still runs inside the host sandbox. macOS's per-thread write switch closes this for threads that aren't writing code at the time.
- **The launcher.** Its requests are an index, arguments, and descriptors. A compromised h9 can run any listed command with any arguments, which is what the plan allowed the guest, and start stubs of the fixed image.
- **The network** is coarse: Landlock limits TCP by port, not address, and Seatbelt's remote rules aren't much finer. The dialer's checks still apply to the guest, but a compromised h9 can connect wherever the host sandbox lets it.
- **Hypervisor, KVM, and WHP interfaces** stay reachable, since the machine runs on them.
- **Kernel bugs** in Seatbelt, Landlock, or seccomp themselves.
- **Hosts without a layer** under `auto`, which `--print` reports.

## Done criteria

- [ ] On macOS and Linux, a guest that escaped into the h9 process couldn't read a host file outside the policy's paths: `test "after the host sandbox, h9 can't open a file outside its handles [host-sandbox]"`, a test hook that makes h9 itself try.
- [ ] On macOS, Linux, and Windows, `test "after the host sandbox, h9 can't map new executable memory [host-sandbox]"` passes.
- [ ] On macOS, Linux, and Windows, `test "after the host sandbox, h9 can't start a host process [host-sandbox]"` passes.
- [ ] `test "the launcher runs only the plan's commands [host-sandbox]"` passes.
- [ ] The integration suite passes with `--host-sandbox=require` on macOS (HVF and `emu`), Linux (KVM, `native`, and `emu`, with `H9_EMU_TIER` set to each tier), and Windows (WHP and `emu`).
- [ ] `--gfx` works under the host sandbox on macOS and Linux.
- [ ] `h9 --host-sandbox=require` in a process that's already sandboxed exits 125.
- [ ] `--print` shows `host.sandbox` and its rules, and `--check` the layers the host has.
- [ ] [spec/sandbox.md](../spec/sandbox.md) describes the host sandbox and the launcher.

## Implementation

1. The research notes: Linux on KVM, `native`, and `emu`, including the seccomp allowlist each needs, from `strace` of the integration suite; on macOS, the JIT under a profile with no `dynamic-code-generation` rule, and `--gfx`'s lookups; and on Windows, WHP and the JIT's two views under the mitigation policies.
2. `src/host/sandbox.zig` and the macOS implementation, with `--host-sandbox` and the escape tests.
3. Linux: Landlock from the handles, and seccomp.
4. The launcher, and host commands, credential helpers, and native stubs moved onto it.
5. Windows: the mitigation policies.
6. `--print`, `--check`, and the spec.

## Open issues

- An AppContainer or a restricted token on Windows, and whether WHP works inside one.
- Which host threads exist when the sandbox is applied, and whether Landlock's thread sync is common enough on target kernels to rely on.
- Whether `auto` should warn when no layer applies at all, or only say so in `--print`.
- Whether `--profile=tight` should imply `require`.
- How much of the macOS research note's "no `mach-lookup` for HVF" holds for `--gfx` and the resolver, which need some.
