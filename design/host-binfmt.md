---
slug: host-binfmt
title: Running 9front binaries directly on Linux with binfmt_misc
status: draft
created: 2026-11-05
authors: [progrium]
depends: []
areas: [cli, build, tests]
---

# Proposal: Running 9front binaries directly on Linux with binfmt\_misc

Nov 5, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

On Linux, h9 can be registered with `binfmt_misc` for the 9front a.out magics, so that `./hello`, or a 9front binary found on the host's `$PATH`, runs through h9 without typing `h9`, as `qemu-user` does for foreign ELF binaries. h9 gains an `h9-binfmt` entry point for the kernel to call and prints the registration, which the administrator installs. It works the same on every backend.

## Background

This was an open question in SPEC.md, then in [kvm](0016-kvm.md), where it didn't belong: it has nothing to do with the backend.

- **Today** a 9front binary on the host runs as `h9 ./prog`. SPEC.md's CLI rules make an argument starting with `./` or `../` a host path, and an absolute one a guest path.
- **The magics** are big-endian at offset 0: arm64 (`R_MAGIC`) is `00 00 8c 47`, amd64 (`S_MAGIC`) is `00 00 8a 97`, and 386 (`I_MAGIC`, [i386](0009-i386.md)) is `00 00 01 eb`.
- **`binfmt_misc`** matches a file's leading bytes and runs `interpreter path args...`, or with the `P` flag `interpreter path argv0 args...`. It can't add arguments of its own, and `path` is whatever was given to `execve`, relative or absolute. Registering a rule needs root.

Non-goals:

- **9front binaries run from a [linux-personality](0018-linux-personality.md) process.** That process's `execve` is a syscall served by h9, not by the host kernel, so `binfmt_misc` never sees it. The personality proposal covers it: each exec picks the personality by magic.
- **Host Linux binaries.** The rules match only the a.out magics, never `\x7fELF`.
- **macOS and Windows.** Neither has an equivalent. A Windows file association needs an extension, which 9front binaries don't have.

## Proposal

### `h9-binfmt`

A second name for the h9 binary, installed as a link beside it. `main.zig` checks the base name of `argv[0]`. Run as `h9-binfmt path argv0 args...`:

- `path` is always a host path, relative or absolute, read on the host as `h9 ./prog` reads one. The rule that an absolute argument is a guest path doesn't apply, since the kernel passes whatever path was exec'd.
- `argv0` becomes the guest's `argv[0]`, so a binary run through a symlink sees the name it was run by.
- h9 parses none of `args`: all of them go to the program, so `./prog --help` reaches `prog`.
- Otherwise it's `h9 ./prog args...`: the default profile, the host cwd at `/mnt/term/cwd`, `--backend auto`, and the same exit codes.
### Settings from the environment

With no command line of its own, `h9-binfmt` reads `H9ROOT` as h9 does today, then the default root. `H9FLAGS`, parsed as h9's flags are, sets anything else, such as `--profile=tight` or `--backend emu`. A program, `--rc`, or flags that only make sense on a command line, such as `--check` and `--print`, are refused in `H9FLAGS` with exit 125.

### Registration

`h9 --binfmt-conf` prints one `systemd-binfmt` line per architecture this h9 can run, naming `h9-binfmt` beside the running binary:

```
:h9-arm64:M::\x00\x00\x8c\x47::/usr/local/bin/h9-binfmt:PF
:h9-amd64:M::\x00\x00\x8a\x97::/usr/local/bin/h9-binfmt:PF
```

The README shows installing it as `/etc/binfmt.d/h9.conf`, and the one-off form, a line written to `/proc/sys/fs/binfmt_misc/register`. h9 never writes to `binfmt_misc` itself.

- `P` passes the original `argv[0]`.
- `F` opens the interpreter when the rule is registered, so the rule also works in containers and chroots that don't have `h9-binfmt`.
- `C` and `O` aren't set: 9front binaries have no setuid bits to honour, and `O` would only help with execute-only files.
### `--check`

On Linux, `--check` reports, for each architecture this h9 runs, whether a `binfmt_misc` rule for its magic is registered and enabled, and the interpreter it names. A missing rule is reported, not a failure.

### Nested h9

With the rule registered, any host process that runs a 9front binary starts a new h9. That includes host commands started by a guest through devcmd (`--host-cmd`). The new h9 has the host user's rights and the default profile, not the outer guest's policy. h9 sets `H9_NESTED=1` in the environment of host commands it starts, and `h9-binfmt` refuses to run when it's set, with exit 125 and a message naming `--host-cmd`. (See Open issues for the alternative.)

## Rationale

**A second name, not a flag.** `binfmt_misc` can't pass the interpreter an argument such as `--exec`. A wrapper script would need a shell and another exec on every run.

**An absolute path is a host path in this mode only.** Making absolute paths host paths everywhere would change the CLI rule for every caller and every script.

**Print the registration, don't install it.** Writing to `binfmt_misc` needs root, and a rule h9 registered itself would outlive an uninstalled h9. A file in `/etc/binfmt.d` is managed by the system like any other.

**Shebang lines.** A 9front a.out can't have one without changing the binary.

**Refuse nested runs by default.** A guest that can run host commands could otherwise run a 9front binary on the host under a fresh default policy, which is broader than the tight profile it may be under. Refusing is the simple safe answer; carrying the policy across is an open issue.

## Compatibility

- Nothing changes unless the rule is registered.
- `h9` behaves as before. `h9-binfmt` and `--binfmt-conf` are new; `H9FLAGS` and `H9_NESTED` are new environment variables.
- **Exit codes:** the same as h9's. A binary for an architecture this h9 can't run is 126, as today.
- **Release archives** for Linux gain the `h9-binfmt` link.
- **Vendored tree:** unchanged.
## Security

- **What a registered rule grants:** nothing beyond what the user has. Every 9front binary any user executes runs through h9 with that user's rights and the default profile, as `h9 ./prog` would. The file still needs its execute bit.
- **The rule matches only the a.out magics,** so host ELF binaries are never routed through h9.
- **`H9FLAGS`** is the user's own environment, so it grants nothing they couldn't get by running h9 with those flags.
- **Nested h9** is refused by default, above.
- **`F`** makes the kernel hold the interpreter open. Replacing h9 on disk doesn't change the registered interpreter until the rule is registered again; the README says so.
## Done when

- These run `h9-binfmt` directly, so they need no root:
  - `test "h9-binfmt runs a host path given as absolute [host-binfmt]"`
  - `test "h9-binfmt passes argv0 and flag-like arguments through [host-binfmt]"`
  - `test "h9-binfmt reads H9ROOT and H9FLAGS [host-binfmt]"`
  - `test "h9-binfmt refuses to run nested [host-binfmt]"`
  - `test "h9 --binfmt-conf prints a rule per architecture [host-binfmt]"`
- `test "./hello runs through binfmt_misc [host-binfmt]"`, which skips unless the rule is registered. The Lima `linux` VM registers it when provisioned, so the case runs there.
- Demo, in the `linux` VM: `sudo sh -c 'h9 --binfmt-conf > /etc/binfmt.d/h9.conf' && sudo systemctl restart systemd-binfmt`, then `./zig-out/fixtures/hello` and `h9 --check`.
## Implementation

1. `h9-binfmt` in `main.zig`, `H9FLAGS`, and `H9_NESTED` set for devcmd's host commands. The cases that run it directly.
2. `--binfmt-conf` and the `--check` report.
3. The `h9-binfmt` link in the build and the release archives; registration in the Lima `linux` VM's provisioning.
4. README (registration, `H9FLAGS`, nested runs) and SPEC.md (the CLI's program rules and exit codes). Set `status: implemented`.
## Open issues

- A link to the h9 binary, or a separate small binary. A link is simpler, but puts a name check in `main.zig`.
- Whether `H9FLAGS` is wanted at all, or `H9ROOT` is enough.
- Nested runs: refuse them, or have the outer h9 pass its policy (as a file or a descriptor) for the inner one to apply, so the inner one is no broader. Refusing is proposed.
- The interpreter path `--binfmt-conf` writes: beside the running binary, or a fixed `/usr/local/bin`, with a flag to override.
