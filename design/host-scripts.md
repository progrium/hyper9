---
slug: host-scripts
title: Running host scripts as the program
status: draft
created: 2026-11-06
authors: [progrium]
depends: []
areas: [cli, machine, tests]
---

# Proposal: Running host #! scripts as the program

[Sign here by hand once you've reviewed the whole doc and take responsibility for it, as described under Signature in README.md. Tools and agents never add the signature.]

## Abstract

`h9 ./greet`, where `greet` is a host file starting with `#!/bin/rc`, fails with `not a 9front executable` (126). h9 should run it as exec does inside the machine: load the interpreter from the guest namespace and pass it a guest path to the script.

## Background

- **Guest programs** (`h9 man`, `h9 /mnt/term/cwd/greet`) follow `#!` in the first process as exec does, since the fix that shares exec's `#!` handling with `startFirst`.
- **Host programs** (`./x`, `../x`) are read on the host by the CLI and passed to the machine as `Program.bytes`. SPEC.md promises that such a program "doesn't need to be in the guest namespace". That works for an a.out, which is loaded from its bytes, but not for a script: the interpreter, a guest program, opens the script by a name, and `bytes` has none.
- **Today's workaround** is `h9 rc ./greet`, which works when the script is under the cwd (or another bound path), since rc opens it at `./greet` relative to the guest cwd `/mnt/term/cwd`.

## Proposal

[To be decided; see Open issues. The leading option: when a host program starts with `#!`, the CLI passes a guest path for it instead of its bytes, mapping a host path under the cwd to `/mnt/term/cwd/...` (and under a `--readable`/`--writable` path to its `/mnt/term/...` view). A script outside every bound path is an error with a message pointing at `--readable`.]

## Rationale

Alternatives:

- **Map the host path into the guest namespace** (leading option). Simple, uses the sandbox as is, and the script sees itself at a real path (`$0`). It breaks the "doesn't need to be in the namespace" promise for scripts only.
- **Serve the script's bytes from a synthetic file** (for example `/fd/N` or a one-file `#|`/ramfs bind). Keeps the promise, but `$0` is a meaningless path and scripts that look at their own directory break; it also adds a kernel-side mechanism for one case.
- **Bind the script's directory read-only automatically.** Widens the sandbox implicitly, which the policy design avoids.
- **Leave it, and document `h9 rc ./x`.** Costs nothing, but `./x` working for binaries and not scripts is surprising.

## Compatibility

- Exit codes: a host `#!` file that gives 126 today would run, or give 127 if the interpreter is missing.
- `Machine.Program` may gain a variant, or the CLI may switch to `.guest` for scripts; either way the `Machine` API or its documented use changes.
- `--arch`: a script has no a.out header, so without `--arch` the machine runs the host's architecture, as for a guest program.

## Security

The interpreter is resolved in the guest, so a `#!/usr/bin/python` line can't run a host program. The script must be readable through the policy, so `--read-deny` and the tight profile apply to it like any other file. With the leading option nothing new is reachable.

## Done criteria

- [ ] `h9 ./greet world` runs a `#!/bin/rc` script in the host cwd and prints its arguments.
- [ ] Integration cases: a host script in the cwd runs, with `$0` the guest path; a host script outside every bound path fails with a clear message; a missing interpreter gives 127.

## Implementation

1. Decide the open issues.
2. In `src/main.zig`, detect `#!` in a host program and resolve its guest path.
3. Pass it as a guest program (or the new `Program` variant), and update SPEC.md's program resolution table and the README.

## Open issues

- Keep the "doesn't need to be in the namespace" promise for scripts (synthetic file), or limit host scripts to bound paths?
- Should a script outside the bound paths get its directory bound read-only, or be an error?
