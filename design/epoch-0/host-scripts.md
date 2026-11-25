---
slug: host-scripts
title: Running host scripts as the program
status: implemented
created: 2026-11-06
authors: [progrium]
depends: []
areas: [cli, machine, tests]
branch: [main]
---

# Proposal: Running host #! scripts as the program

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

`h9 ./greet`, where `greet` is a host file starting with `#!/bin/rc`, fails with `not a 9front executable` (126). h9 should run it as exec does inside the machine: load the interpreter from the guest namespace and pass it a guest path to the script.

## Background

- **Guest programs** (`h9 man`, `h9 /mnt/term/cwd/greet`) follow `#!` in the first process as exec does, since the fix that shares exec's `#!` handling with `startFirst`.
- **Host programs** (`./x`, `../x`) are read on the host by the CLI and passed to the machine as `Program.bytes`. [spec/cli.md](../../spec/cli.md) promises that such a program "doesn't need to be in the guest namespace". That works for an a.out, which is loaded from its bytes, but not for a script: the interpreter, a guest program, opens the script by a name, and `bytes` has none.
- **Today's workaround** is `h9 rc ./greet`, which works when the script is under the cwd (or another bound path), since rc opens it at `./greet` relative to the guest cwd `/mnt/term/cwd`.

## Proposal

When a host program starts with `#!`, the CLI runs it as a guest program by its guest path instead of passing its bytes. The `Machine` API doesn't change: the CLI passes `.guest` with that path, and the machine follows `#!` as it does for any guest program.

The CLI resolves the host path, symlinks included, and maps it as the compiled policy binds it:

- under the cwd: `/mnt/term/cwd/...`
- in a root `--dir`: its path in the root
- under a `--readable` or `--writable` path, or anywhere with `--host-fs`: `/mnt/term/<host path>`
- under another `--dir` mount: its path under the mount's destination

A script the policy doesn't let the guest read, because it's outside every bound path or a `--read-deny` path hides it, is an error before the machine starts, with exit code 126 and a message naming the flag that would share it (`--readable DIR`) or the `--read-deny` path that hides it. Nothing is bound for the script.

## Rationale

Alternatives:

- **Map the host path into the guest namespace** (chosen). Simple, uses the sandbox as is, and the script sees itself at a real path (`$0`). It breaks the "doesn't need to be in the namespace" promise for scripts only.
- **Serve the script's bytes from a synthetic file** (for example `/fd/N` or a one-file `#|`/ramfs bind). Keeps the promise, but `$0` is a meaningless path and scripts that look at their own directory break; it also adds a kernel-side mechanism for one case.
- **Bind the script's directory read-only automatically.** Widens the sandbox implicitly, which the policy design avoids.
- **Leave it, and document `h9 rc ./x`.** Costs nothing, but `./x` working for binaries and not scripts is surprising.

## Compatibility

- Exit codes: a host `#!` file that gave 126 runs, or gives 127 if the interpreter is missing, or still 126 if the guest can't read it.
- `Machine.Program` is unchanged; the CLI uses `.guest` for scripts. spec/cli.md's promise that a host program "doesn't need to be in the guest namespace" now holds for binaries only.
- `--arch`: a script has no a.out header, so without `--arch` the machine runs the host's architecture, as for a guest program.

## Security

The interpreter is resolved in the guest, so a `#!/usr/bin/python` line can't run a host program. The script must be readable through the policy, so `--read-deny` and the tight profile apply to it like any other file. Nothing is bound for the script, so nothing new is reachable.

## Done criteria

- [x] `h9 ./greet world` runs a `#!/bin/rc` script in the host cwd and prints its arguments.
- [x] Integration cases: a host script in the cwd runs, with `$0` the guest path; a host script outside every bound path fails with a clear message; a missing interpreter gives 127.

## Implementation

1. In `src/policy.zig`, `guestPath` maps a resolved host file to its guest path under a compiled plan, or null if the guest can't read it.
2. In `src/main.zig`, detect `#!` in a host program, resolve its host path, and, once the plan is compiled, pass its guest path as a guest program.
3. Update spec/cli.md's program resolution, and the manual.

## Open issues

None. Both were decided for the leading option: host scripts are limited to the bound paths, and a script outside them is an error rather than getting its directory bound.

## Updates

- 2026-11-25: Implemented as the leading option. The integration case `a host #! script runs by its guest path [host-scripts]` covers the cwd, a subdirectory, a `--readable` path, a script outside every bound path, `--read-deny`, and a missing interpreter.
