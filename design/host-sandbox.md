---
slug: host-sandbox
title: Host self-sandboxing
status: draft
created: 2026-11-03
authors: [progrium]
depends: [kvm, whp]
areas: [sandbox]
---

# Proposal: host self-sandboxing

## Abstract

Compile the sandbox policy into a host sandbox as well, and apply it to the h9 process itself after VM creation and root setup: Seatbelt on macOS, Landlock and seccomp on Linux, and an AppContainer or restricted token on Windows. Defence in depth for drawterm's C kernel, which runs with the host user's full rights.

## Background

This was planned for after milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is DESIGN.md's "Host self-sandboxing (future)" section as it stood there, including the macOS research note. Rationale, Compatibility, Security and Implementation are to be written before filing.

The guest is contained, but the h9 process runs drawterm's C kernel with the host user's full rights, and drawterm's `validaddr` is a no-op, so h9's own guest-address translation is the memory-safety boundary. Defence in depth is to compile the same policy into a host sandbox and apply it to h9 after VM creation and root setup, in a `src/hostjail.zig` with one implementation per OS, following the vmm pattern. Running h9 under gVisor doesn't work, because gVisor can't pass `/dev/kvm` through.

This is future work. Each backend proposal records a research note so this can be built later:

- **macOS (done, below):** whether `sandbox_init` with a generated SBPL profile can be applied after `hv_vm_create` and still allow HVF calls, and which profile rules that needs. See the research note below.
- **macOS, [gfx](gfx.md):** which Mach and WindowServer lookups `--gfx` needs under Seatbelt.
- **Linux, [kvm](kvm.md):** Landlock for paths and TCP ports plus seccomp, with `/dev/kvm` already open; the syscalls `KVM_RUN` and vCPU threads need; the Landlock ABI each target distro ships.
- **Windows, [whp](whp.md):** whether an AppContainer or restricted token can still use WHP.

**Research note: Seatbelt with HVF.** Tested on macOS 15.8.1 on an M3 Max with a small C program, ad-hoc signed with the hypervisor entitlement. It calls `hv_vm_create` and `hv_vm_map` on 16 MiB of guest RAM, then applies a profile with `sandbox_init_with_parameters`. That call is exported from libsystem_sandbox but not declared in `<sandbox.h>`, so it needs its own prototype. The profile was:

```scheme
(version 1)
(deny default)
(allow file-read* (subpath (param "ALLOWED")))
```

After that it creates a vCPU on each of two new pthreads, runs them to an `hvc #0`, maps and unmaps a second region, and opens files. Everything HVF worked under `(deny default)` with no other rules: `hv_vcpu_create` on new threads, `hv_vcpu_run` (exit reason exception, syndrome `0x5a000000`), `hv_vm_map`/`hv_vm_unmap` of new memory and `hv_vm_destroy`. Thread creation needed no rule either. HVF needs no `iokit-open` or `mach-lookup` rule, because the VM and vCPUs are reached through the process's existing hypervisor handle, which is allowed by the entitlement rather than by the sandbox. Applying the same profile *before* `hv_vm_create` also worked, so ordering isn't forced by HVF. File rules behaved as expected, with one catch: `ALLOWED` must be the resolved path (`/private/var/...`, not `/var/...`), because the sandbox matches resolved paths. Reads inside it worked, writes there and reads elsewhere (`/etc/hosts`) failed with EPERM, and the process kept running. `sandbox_init*` fails with EPERM when the process is already sandboxed, so hostjail has to treat that as "already contained" or fail closed under `--strict`. For `src/hostjail.zig`, the plan is a generated `(deny default)` profile listing the resolved root, cwd and `--readable`/`--writable` paths (read or read-write), `/dev/null`, the TTY, and `network-outbound` only when the policy allows the network. It's applied after the backend and root setup, and before the first guest instruction runs.

## Done when

- On each host, a guest that escaped into the h9 process couldn't read a host file outside the policy's paths: checked with a test hook that makes h9 itself try, after the host sandbox is applied.
