---
slug: renames
title: Rename the parts, to ABI, engine, sud, and hcpu
status: draft
created: 2026-11-21
authors: [progrium]
depends: [hcpu]
areas: [process, vmm, linux, cli, build, tests]
branch: []
---

# Proposal: Rename the parts, to ABI, engine, sud, and hcpu

## Abstract

Four of h9's names no longer say what they name. A personality becomes an ABI. The `vmm` layer and its backends become engines. The `native` backend becomes `sud`. The emulator backend, which is `emu` on the command line, hcpu in the build, and `v86` as an alias, becomes `hcpu` everywhere. The source tree, the CLI, the `Machine` API, the build options, and the spec change to match, and the old CLI spellings stay as aliases for one release. Nothing changes in behaviour. It's the last change of epoch 0, so that `baseline-1` is written in the new words and no later proposal needs a table of old names.

## Background

Each name was right when it was chosen, and h9 has since grown past it.

- **Personality.** [linux-personality](epoch-0/linux-personality.md) added Linux as a guest inside a Plan 9 runner, and "personality" fit: one native system and a mask. Linux is now the larger consumer of the kernel, and what's picked at exec is a binary format, a system call table, a signal or note frame, and a default view of the namespace. That's an ABI, and the spec already says so: [spec/abi-plan9.md](../spec/abi-plan9.md) and [spec/abi-linux.md](../spec/abi-linux.md) are named for it, while their text, 124 identifiers and comments under `src/`, and the proposal checklist in [README.md](README.md) still say personality.
- **`vmm` and backend.** `src/vmm.zig` began as a wrapper over three hypervisor APIs. Of the six implementations behind it now, three are hypervisors (HVF, KVM, and WHP). The others are stub processes on Syscall User Dispatch, Unicorn, and h9's own interpreter and JIT, and [spec/engines.md](../spec/engines.md) is already named for what they have in common. "Backend" also names drawterm's GUI backends (`--gfx`), so "the backend" needs a qualifier every time.
- **`native`.** [native-backend](epoch-0/native-backend.md) named it for running guest code on the host CPU. Every hypervisor does that too, so the name doesn't tell it apart, and `hvf`, `kvm`, and `whp` are each named for the host feature they're built on. This one is built on Syscall User Dispatch.
- **`emu`, hcpu, and `v86`.** The CLI says `--backend emu`, the build says `-Demu=hcpu`, the code says hcpu, and `v86` is still accepted. Once [hcpu](hcpu.md) is implemented, `emu` in a release build means hcpu and nothing else.

The names appear in these places today:

| Where | Today |
| --- | --- |
| CLI | `--backend auto\|hvf\|kvm\|whp\|native\|emu`, with `v86` as an alias of `emu`; `--check` and `--version` list "backends" |
| `Machine` API | `Machine.Options.backend`, `vmm.BackendKind`, `vmm.Backend`, and `error.BackendNotBuilt` |
| Build | `-Dbackends` for `zig build integration`; `-Demu=unicorn\|hcpu` |
| Environment | `H9_EMU_TIER`, `H9_EMU_DETERMINISTIC`, and `H9_EMU_NO_CODEGEN` |
| Source | `src/vmm.zig` and `src/vmm/`; `src/vmm/native.zig`, `native_abi.zig`, and `native_stub.zig`; `src/hcpu.zig`, `src/interp/`, `src/jit/`, and the CPUs in `src/vmm/`; `src/linux/`; `src/aout.zig`, `src/loader.zig`, and `src/syscall.zig` |
| Prose | SPEC.md, `spec/`, README.md, MANUAL.md, DEVELOPING.md, AGENTS.md, `docs/`, the site, and comments |

## Proposal

### The names

| Today | After | Notes |
| --- | --- | --- |
| personality | ABI | "The Linux ABI" and "the 9front ABI". A process has one, picked at exec. |
| `vmm`, backend | engine | What runs a process's code and turns its system calls and faults into exits. "Backend" is kept for the GUI backends. |
| `native` | `sud` | For Syscall User Dispatch, as `kvm` is for KVM. Prose says "the sud engine". |
| `emu`, `v86` | `hcpu` | h9's own CPUs. h86, ha64, hx64, T0, and T1 keep their names. A `-Demu=unicorn` build's emulator is the `unicorn` engine. |
| browser host, web host | web host | One term for the wasm32-wasi build, under Node or in a page. "Browser" is for what only a page has. |

Machine, kernel, root, plan, policy, shim, and the device names don't change.

### CLI

- `--engine auto|hvf|kvm|whp|sud|hcpu` replaces `--backend`. In a `-Demu=unicorn` build, `unicorn` is a value too.
- `--backend` is accepted as an alias of `--engine`, and `native`, `emu`, and `v86` as aliases of `sud`, `hcpu`, and `hcpu`, for one release. The usage text and the manual don't mention them. After that release each is a usage error, as [hcpu](hcpu.md) already says of `v86`.
- `--check` and `--version` say "engines" where they say "backends", and name them `sud` and `hcpu`.
- `--print` and exit codes don't change.

### The `Machine` API, the build, and the environment

- `Machine.Options.backend` becomes `Machine.Options.engine`. The `vmm` module becomes `engine`, with `engine.Choice` for `vmm.BackendKind`, `engine.Engine` for `vmm.Backend`, `engine.Kind`'s fields `sud` and `hcpu`, and `error.EngineNotBuilt`. There are no aliases: the Zig API isn't stable yet, and a compile error names the fix.
- `-Dbackends` becomes `-Dengines`, with the new values. `-Demu=unicorn|hcpu` keeps its name, since it picks which emulator is built in.
- `H9_EMU_TIER`, `H9_EMU_DETERMINISTIC`, and `H9_EMU_NO_CODEGEN` become `H9_HCPU_TIER`, `H9_HCPU_DETERMINISTIC`, and `H9_HCPU_NO_CODEGEN`, with no aliases. They're for tests and debugging.
- The page's `createMachine` doesn't take an engine, and doesn't change.

### The source tree

Only the directories whose names change move:

```text
src/
  engine.zig         was vmm.zig
  engine/            was vmm/
    hvf.zig, kvm.zig, whp.zig, unicorn.zig, none.zig, ...
    sud.zig, sud_abi.zig, sud_stub.zig     were native*.zig
    hcpu/            was src/hcpu.zig, src/interp/, src/jit/, and vmm/{hcpu,h86,ha64,hx64,x86,lockstep}.zig
  abi/
    plan9/           was src/aout.zig, src/loader.zig, and src/syscall.zig
    linux/           was src/linux/
  kern/              stays; linux.c, linuxnet.c, and devlinux.c keep their names
```

Identifiers and comments follow: `Backend` types and `backend` fields that mean an engine, and "personality" wherever it appears. The `areas` tag `vmm` becomes `engine` in the template and in proposals that are still drafts.

### The spec and the docs

- SPEC.md, `spec/`, README.md, MANUAL.md, DEVELOPING.md, AGENTS.md, `docs/`, and the site use the new names. SPEC.md's title, "Plan 9 executables on host hypervisors", stays until `baseline-1` restates what h9 is.
- [spec/cli.md](../spec/cli.md) documents `--engine` and its aliases. `spec/host-js.md` becomes `spec/host-web.md`, and SPEC.md's index follows.
- [README.md](README.md)'s list of what needs a proposal says "the engine interface" and "new engines, ABIs, devices, or root types".
- [README.md](README.md) gains a short table of old names, so a reader of an epoch-0 proposal can find what "the native backend" or "the Linux personality" is called now.

### What doesn't change

- **Proposals.** Slugs are permanent, so `linux-personality`, `native-backend`, and the rest keep theirs, and so do their titles, their bodies, and the test tags that name them. Archived proposals aren't edited. Proposals at the top of `design/` that are proposed or accepted aren't edited either; drafts may be.
- **`third_party/`.** Nothing there is renamed.
- **Devices.** `#λ`, `#ℏ`, `#ℓ`, `#ε`, `#μ`, and the others keep their runes. Named devices would change how the kernel parses a device spec, which is more than a rename.
- **The rest of the tree.** Splitting `src/kern/` into devices and 9P, and `src/machine.zig` and `src/kern.zig` into smaller files, is a reorganization with design questions of its own.

## Rationale

**Why ABI.** It's what's chosen at exec, and FreeBSD and the spec's own file names use the word this way. It also separates what a process speaks from what runs its code, which "personality" blurs: a process on a JavaScript engine that makes Linux system calls would be a new engine and not a new ABI. "Personality" is Linux's word for a different thing, `personality(2)`, which the Linux ABI implements.

**Why engine.** "Hypervisor" is wrong for half of them. "Backend" is taken by the GUI backends and says nothing about what it's a backend of. "Executor" and "runner" suggest scheduling, which belongs to the kernel. "CPU" would fit hcpu and nothing else. "Engine" is already the spec file's name.

**Why `sud`.** `native` doesn't distinguish it from HVF, KVM, and WHP. `stub` names an implementation detail, the process the guest's code runs in, that the Mac and Windows equivalents wouldn't share. `systrap` is gVisor's name for a similar design, and would suggest a compatibility that isn't there. `sud` names the host feature, as the three hypervisor engines' names do, and it's three letters like them. A port to another host's mechanism would get its own name, as each hypervisor did.

**Why `hcpu` and not `emu`.** One thing has three names today. `emu` describes a category, and with Unicorn retired from releases the category has one member. `hcpu` is what the code, the build, and the spec files call it.

**Why aliases on the CLI and nowhere else.** `--backend emu` and `--backend native` are in CI configurations, container images, and other people's scripts, and a usage error there costs someone else an afternoon. A Zig embedder gets a compile error with the new name one line away. One release matches what hcpu decided for `v86`.

**Why now, and why in one proposal.** A rename conflicts with every open branch, so it wants to land when the fewest are open, and it wants to land once. Doing it before `baseline-1` means the new baseline, and every proposal in epoch 1, is written in one vocabulary. Doing it at the start of epoch 1 instead would put the first proposals of the epoch in the old words, or make them wait.

**Why not move the whole tree.** The larger layout (`kern/dev/`, `kern/ninep/`, `host/`, `machine/`, and `cmd/`) depends on where [namespace-kernel](namespace-kernel.md) draws the kernel's edge, which isn't decided. Moving files twice is worse than moving them once, later.

**Why not edit old proposals.** They're a record, and their slugs can't change anyway, so they'd be half-renamed at best. A table of old names in README.md costs less and doesn't touch an accepted body.

## Compatibility

- **CLI.** `--engine` is new. `--backend`, `native`, `emu`, and `v86` keep working for one release and are then usage errors (exit 2). The `--check` and `--version` text changes, which matters to anything that parses it.
- **Exit codes, `--print`, sandbox defaults, and the root tree.** Unchanged.
- **`Machine.Options` and the Zig API.** `backend` becomes `engine`, and the `vmm` module becomes `engine`, with no aliases. [docs/embedding.md](../docs/embedding.md) is updated.
- **Build.** `-Dbackends` becomes `-Dengines`. The `H9_EMU_*` variables become `H9_HCPU_*`.
- **Open branches.** Every branch that touches `src/vmm/`, `src/linux/`, or the loaders needs a rebase. Git follows the renames, so the conflicts are in lines that say backend or personality.
- **Links.** `spec/host-js.md` moves, and `check` doesn't cover links to `spec/`, so the PR that moves it greps for them.
- **`third_party/`.** Unchanged.

## Security

None. No code path changes, and the guest can reach nothing new. The sud engine still isn't a security boundary, `auto` still never selects it, and the alias `native` is treated exactly as `sud` is, including that rule.

## Done criteria

- [ ] `h9 --engine hcpu /bin/echo hi` and, on a Linux x86\_64 host, `h9 --engine sud /bin/echo hi` print `hi`.
- [ ] `test "--engine and its values [renames]"` in `src/cli.zig` parses each of `auto`, `hvf`, `kvm`, `whp`, `sud`, and `hcpu`.
- [ ] `test "--backend, native, emu, and v86 are aliases [renames]"` in `src/cli.zig` shows each old spelling parses to the same Config as the new one, and that the usage text names none of them.
- [ ] `test "auto never selects sud, by either name [renames]"` passes.
- [ ] `h9 --check` and `h9 --version` list engines, as `sud` and `hcpu`.
- [ ] `zig build test`, `zig build integration`, `zig build integration -Dweb`, and `zig build web-test` pass with the same cases as before the rename, and none newly skipped.
- [ ] `git grep -il personalit` finds only `design/`, `third_party/`, and the Linux ABI's `personality(2)`.
- [ ] `git grep -wl vmm` finds only `design/` and `third_party/`.
- [ ] SPEC.md, `spec/`, README.md, MANUAL.md, DEVELOPING.md, AGENTS.md, and `docs/` use the new names, and [README.md](README.md) has the table of old names.
- [ ] `zig build design -- check` passes.

## Implementation

Each step is one PR that changes names and nothing else, so its diff can be reviewed as a rename. The steps are ordered to keep each one small, and each leaves main passing.

1. Wait for [hcpu](hcpu.md) to be implemented, and for the branches open at the time to land or agree to rebase.
2. `native` to `sud`: the three files, `engine.Kind`'s field, the CLI value with its alias, and the prose.
3. `emu` and `v86` to `hcpu`: the CLI values with their aliases, the `H9_EMU_*` variables, and the prose.
4. `vmm` and backend to engine: `src/vmm.zig` and `src/vmm/` move, the hcpu files gather under `src/engine/hcpu/`, `--engine` arrives with `--backend` as its alias, and `Machine.Options.backend`, `-Dbackends`, and the identifiers follow.
5. Personality to ABI: `src/abi/plan9/` and `src/abi/linux/`, the identifiers and comments, and the prose.
6. The docs: `spec/host-js.md` to `spec/host-web.md`, "web host" throughout, the process list and the table of old names in [README.md](README.md), and the `areas` tag.
7. Check off Done criteria, and set `status: implemented` and `branch: [main]`.
8. A release later, make `--backend`, `native`, `emu`, and `v86` usage errors.

## Open issues

- Whether step 8 belongs to this proposal or to the release that does it. As written, the proposal is implemented at step 7, and step 8 is a line in that release's notes.
- Whether `src/kern/linux.c`, `linuxnet.c`, and `devlinux.c` should move under `src/abi/linux/` now. They're C compiled with the kernel, and the proposal leaves them where the kernel's build expects them.
- Whether SPEC.md's title should change here or wait for `baseline-1`. The proposal waits.
