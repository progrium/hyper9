---
slug: plan-format
title: The plan as a file, and the one way in
status: draft
created: 2026-11-21
authors: [progrium]
depends: [baseline-1, mounts, child-machines]
areas: [cli, sandbox, kern, web, tests]
branch: []
---

# Proposal: The plan as a file, and the one way in

## Abstract

Every run of h9 compiles its flags into a plan: a namespace, a policy, and limits. `--print` shows it, and `--ns` replays its namespace. This proposal makes the plan a complete, documented text format, and the one input every way of starting a machine takes. `h9 --plan FILE` runs one. `--print` writes one that `--plan` runs to the same effect. The Zig API, the page's `createMachine`, and a child machine's `ctl` take the same text. Flags stay, as shorthand that compiles to a plan, and a flag given with `--plan` can only narrow it.

## Background

- **The plan exists but isn't an interface.** `--print` shows the namespace, the policy, and the limits in three sections with three syntaxes. Only the namespace section can be fed back, through `--ns`.
- **A flag per idea.** The usage text has about forty flags, and several interact (`--write`, `--sandbox`, `--profile`, `--readable`, and `--writable`). [mounts](mounts.md) reduces the namespace flags to one family where each is one line of the plan, and makes `--print`'s namespace exactly what `--ns` replays.
- **Four front doors.** The CLI takes flags. `Machine.Options` is a struct with a field per flag. `createMachine` takes a JavaScript object with some of them. [child-machines](child-machines.md)' `#μ` takes `ctl` lines such as `memory`, `pids`, `net`, and `writable`. Each is kept in step with the others by hand, and each lacks something another has.
- **No way to hand someone a sandbox.** A recipe in [docs/recipes.md](../docs/recipes.md) is a long command line. It can't be checked in, diffed, reviewed, or pinned.

## Proposal

### The format

A plan is lines of text, in the syntax namespace files already use: a word and its arguments, `#` comments, single quotes, and `;` or a newline between lines. It has three kinds of line.

```text
# namespace: mounts' lines, unchanged
mount -c tcp!registry.example!564 / 'root=alpine-3.22 b3=9f2c…'
bind -c '#Oroot' /
dir ro ./src /src
tmp /tmp

# policy
net outbound
netallow *.example.com:443
write overlay
deny read ~/.ssh

# limits and the run
memory 512M
pids 256
cpus 4
timeout 5m
arch amd64
env HOME=/root
cwd /src
run /bin/sh -c 'make test'
```

- **Namespace lines** are what [mounts](mounts.md) defines, with no change.
- **Policy lines** are one per rule: `net`, `netallow`, `write`, `deny`, `devices`, and `profile`, which expands to its lines.
- **Limit and run lines** are `memory`, `pids`, `cpus`, `timeout`, `engine`, `arch`, `env`, `cwd`, `gfx`, `serve`, and `run`.

Order matters only among namespace lines. A line h9 doesn't know is an error, with the line number.

### `--plan` and `--print`

- `h9 --plan FILE [program args...]` runs a plan. `--plan -` reads standard input. A program on the command line replaces the plan's `run`.
- `h9 [flags] --print` writes the plan those flags compile to, in this format, with every default spelled out. `h9 --plan <(h9 [flags] --print)` runs the same machine.
- Flags given with `--plan` are applied after it and can only narrow: a lower limit, a path made read-only, or a network rule removed. A flag that would widen the plan is exit 2, naming the line it conflicts with.

### Every front door takes a plan

- **Zig.** `Machine.init(gpa, io, .{ .plan = text })`. `Machine.Options`' other fields stay as the struct form of the same thing, and `Options.toPlan()` gives the text.
- **The page.** `createMachine({ plan })`, with handles (`MessagePort`s, a canvas, and a terminal) passed beside it by name.
- **Child machines.** A child's `ctl` takes plan lines, which is nearly what it takes now. Narrowing a child against its parent is the same rule as narrowing a plan with flags, in one implementation.
- **Flags.** Each flag is documented by the plan line it becomes.

### Pinned roots

A `mount` line can carry a content hash for its tree, `b3=…`, from the index [mounts](mounts.md) and [mount-index](mount-index.md) define. A plan with every root pinned describes the same machine wherever it runs, and h9 refuses a tree whose index doesn't match.

## Rationale

**Why text in namespace-file syntax.** It's the format h9 already prints and already parses, it's what Plan 9 uses for the same job, and `ctl` files take lines. JSON or TOML would be a second syntax for the namespace part, which has to stay replayable by `newns`.

**Why flags stay.** `h9 ls` is the product. A plan file is for what's worth keeping.

**Why narrowing only.** A plan that's been reviewed should mean what it says when someone adds a flag. Widening is done by editing the plan.

**Why not design the plan first and derive the flags.** That's what a from-scratch design would do. h9 has the flags, and [mounts](mounts.md) is already reshaping them, so this follows it.

## Compatibility

- **`--print`.** Its output changes format. It's documented as a plan from here on. The namespace part is already what [mounts](mounts.md) makes it.
- **`--ns`.** Unchanged: it takes namespace lines only, and a plan's namespace lines are valid there.
- **Flags and exit codes.** Unchanged, except that a widening flag with `--plan` is exit 2.
- **`Machine.Options` and `createMachine`.** `plan` is new. Existing fields keep working.
- **Child machines' `ctl`.** Its lines become plan lines. Where a name differs, the old one is kept as an alias.

## Security

A plan file is as trusted as a command line: whoever writes it decides what the guest can reach. `--plan` reads it with h9's own permissions, before the machine starts, and never from inside the guest except through a child machine's `ctl`, where the parent's limits bound it. The narrowing rule is the security property, and it has one implementation shared by flags and child machines. A pinned root makes a tampered tree a refusal instead of a different machine.

## Done criteria

- [ ] `h9 --plan <(h9 --rc 'ls /bin | wc -l' --print)` prints what `h9 --rc 'ls /bin | wc -l'` prints.
- [ ] `test "--print output round-trips through --plan for every policy case [plan-format]"` passes: the compiled plans are equal.
- [ ] `test "a flag after --plan narrows, and a widening flag is exit 2 [plan-format]"` passes for memory, a writable path, and `--net`.
- [ ] `test "an unknown plan line is an error with its line number [plan-format]"` passes.
- [ ] `test "Machine.init from a plan equals Machine.init from Options [plan-format]"` passes.
- [ ] `await test('createMachine({ plan }) runs rc [plan-format]', ...)` passes in `tests/web/`.
- [ ] `test "a child's ctl takes plan lines, bounded by its parent [plan-format]"` passes.
- [ ] `test "a pinned root with a different index is refused [plan-format]"` passes.
- [ ] [spec/cli.md](../spec/cli.md) documents each flag by its plan line, [spec/sandbox.md](../spec/sandbox.md) documents the format, and [docs/recipes.md](../docs/recipes.md) has each recipe as a plan.

## Implementation

1. The format's grammar and parser in `src/policy.zig`, beside the namespace parser it extends, with the printer as its inverse and a round-trip test.
2. `--print` in the format, and `--plan`.
3. The narrowing rule, shared with child machines.
4. `Machine.Options.plan`, `toPlan`, and `createMachine({ plan })`.
5. Pinned roots.
6. The spec and the recipes.

## Open issues

- The file's name and whether h9 looks for one. As written there's no default: a plan is run only when named.
- Whether `run` belongs in the plan or the plan describes only the machine. As written it's optional.
- How a plan names handles that can't be text, such as a `MessagePort` on the page or an embedder's directory handle ([host-handles](host-handles.md)). As written, by a name the caller supplies beside the plan.
- Where a registry of roots fits. The plan pins a tree by hash and doesn't say where trees come from.
