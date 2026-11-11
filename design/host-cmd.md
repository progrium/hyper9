---
slug: host-cmd
title: Rethinking host commands
status: draft
created: 2026-11-07
authors: [progrium]
depends: []
areas: [kern, sandbox, cli, build]
---

# Proposal: Rethinking host commands

## Abstract

Host commands run a program on the host from inside the machine. Today that's drawterm's devcmd (`#C`), unmasked by `--host-cmd`: any host program, as the host user, with h9's whole environment, in any host directory. It's now built in only with `zig build -Dhost-cmd`. This proposal decides what host commands should be before they ship again. It recommends replacing devcmd with an h9 device, kept per machine, whose reads a note can interrupt. The new device should run only the commands the policy names, with a scrubbed environment, in host directories the policy already shares. `hcmd` stays the guest's interface.

## Background

What exists today:

- **devcmd** (`third_party/drawterm/kern/devcmd.c`): a guest opens `#C/cmd/clone`, writes `dir path` and `exec cmd args...` to `ctl`, uses `data` for stdin and stdout and `stderr` for stderr, and reads `wait` for the status. `oscmd` in `posix.c` forks, calls `setsid`, `chdir`s, and runs `execvp`. `win32.c` has a `CreateProcess` version.
- **`--host-cmd`** leaves `#C` out of the device mask. The plan adds the caveat "#C runs host commands with the host user's rights". `--sandbox` refuses the flag.
- **`hcmd`** (`src/guest-hostcmd/bin/hcmd`) wraps the protocol: it passes standard I/O through, exits with the command's status, maps the guest's cwd to a host directory from the `#U` binds in `/proc/$pid/ns`, and kills the command on an interrupt or hangup.
- **`src/kern/hostcmd.c`** kills a machine's commands when the machine stops. It does this by renaming `oscmd` in the vendored `posix.c` and `win32.c`.
- **`-Dhost-cmd`**: without it, devtab leaves devcmd out, `hcmd` isn't served, and the policy refuses `host_cmd` with exit 2. Releases don't pass it.

Problems found while adding the tests:

- **It turns the sandbox off.** A host command can reach everything the host user can. That includes paths `fs.read.scope` and `fs.write.scope` hide, the network whatever `--net` says, and every host environment variable even though `env.scrub` holds for the guest. `dir` takes any host path. The plan states this as one caveat, and `--strict` doesn't refuse it.
- **One table for every machine.** devcmd's conversations (`cmd.conv`) are global to the host process. Two machines in one process, as `Machine` allows, see each other's conversations, and both are owned by the host user. This comes from reading the code; no test has shown it yet.
- **Reads can't be interrupted.** `data` and `stderr` reads are blocking host `read`s through devlfd, and no note reaches them. A process reading a command's output can't be interrupted. Before `hostcmd.c`, a stopped machine stayed stuck until its grace period ran out, and the command outlived h9. `hcmd` works around this by reading in the background.
- **Easy to misuse.** `wait` keeps a status only if it was opened before the command exited. Its one message has no newline, so `read` blocks on it. Any close of `ctl` kills the command once `killonclose` is set. Arguments go through `tokenize` quoting. Windows reports `0 0 0 0 N` where POSIX reports `pid 0 0 0 'exit: N'`.
- **Every command can run.** Nothing chooses which host programs a guest may run, and `--print` doesn't show any.
- **The guest maps directories.** `hcmd` works out the host directory by parsing `/proc/$pid/ns`, which depends on its format. Under `--write=ephemeral` the guest's view is an overlay, which the host command doesn't see.

## Proposal

Replace devcmd with an h9 device, `#C` still, in `src/kern/devhcmd.c` with its host side in Zig (`src/hostcmd.zig`). It follows devhstream's pattern ([websocket-9p](websocket-9p.md)).

- **Per machine.** Conversations belong to the machine that made them, as `/net/ws`'s do. A machine lists and opens only its own.
- **Interruptible.** Zig starts the process (`std.process.Child`) and has a host thread per pipe that queues output in the machine's pages. A guest read sleeps on a Rendez, so a note interrupts it with `Eintr`. A write to stdin is queued the same way. The machine's end kills its commands and their process groups, as `hostcmd.c` does now.
- **Commands the policy names.** `--host-cmd NAME` (repeatable) allows `NAME`. The plan resolves it to a host path from the host `PATH` when it's compiled, and `--print` lists each one under `host-cmd:`. `exec` takes a name from that list and nothing else, so `exec sh` fails unless `sh` was allowed. `--host-cmd '*'` keeps today's behaviour and says so as a caveat. A bare `--host-cmd` is a usage error, so nobody gets "everything" by accident.
- **A scrubbed environment.** A command starts with the guest's `--env` values plus `PATH`, `HOME`, `USER`, `LANG`, and `TMPDIR` from the host. `--host-cmd-env NAME` passes another one through.
- **Directories the policy shares.** `dir` takes a guest path. The host translates it through the policy's binds: the cwd, `--readable`, and `--writable` trees, and `--host-fs`. A path that isn't in a shared host tree (`/tmp`, the root, an overlay) is refused. `hcmd` then stops parsing `/proc/$pid/ns`.
- **A simpler protocol.** `wait` keeps the status whether or not it's open, and gives it as one line: `pid 0 0 0 'msg'\n`, the same on every host. `ctl` takes `exec`, `dir`, `kill`, and `close-stdin`. The command is killed when the last fd on the conversation closes, never on a `ctl` close alone.
- **Capability.** The plan gains `proc.host`, "the guest can run the named host programs", which `--strict` refuses unless `--host-cmd` is given. That makes host commands an explicit grant, like `--gfx`.
- **`hcmd`** keeps its interface (`-n`, `-d`, standard I/O, the exit status) and becomes shorter.

When this lands, `-Dhost-cmd` goes away and host commands are built in everywhere except the browser host, where there's no process to start.

## Rationale

- **Keep devcmd and patch it.** Each fix touches `third_party/`: interruptible reads, per-machine tables, the status format, and an allowlist. That's most of the device, and AGENTS.md asks for project-owned code when the change is this large. The rename trick in `hostcmd.c` is fine for one hook but not for five.
- **Remove host commands entirely.** A host shell can already drive h9 from outside (`h9 ... | host-cmd | h9 ...`), and [host-binfmt](host-binfmt.md) goes the other way. Running host tools from inside, such as a host compiler, `git`, or `open`, is still the request people make most, and `mk` recipes need it in-line. Keeping it behind a build flag until it's safe costs little.
- **Run commands under the host sandbox.** [host-sandbox](host-sandbox.md) would confine h9 itself. Children inherit Seatbelt and Landlock, so commands would get the same limits for free, but only on hosts where that lands. The allowlist and the environment scrub are needed either way.
- **A 9P server on the host instead of a device** (as in [host-srv](host-srv.md)). That's workable, but a device gives notes, per-machine lifetime, and the policy hook in one place, as devhstream did for WebSockets.
- **Arguments as a list instead of `tokenize`.** Writing one argument per line after `exec` would avoid quoting, but rc's `echo` and the wider 9front tools already speak `tokenize`, so the quoting stays.

## Compatibility

- **CLI.** `--host-cmd` changes from a switch to `--host-cmd NAME`, and the bare form becomes a usage error (exit 2). `--host-cmd-env NAME` is new. Scripts written against today's flag already need `-Dhost-cmd`, so nothing that ships breaks.
- **`Machine.Options`.** `Policy.host_cmd: bool` becomes `host_cmds: []const []const u8`, plus `host_cmd_env`.
- **Sandbox.** There's a new capability, `proc.host`. The default and tight profiles still have no host commands.
- **`third_party/`.** devcmd stops being built and `oscmd` isn't used. `hostcmd.c` and the `-Doscmd` renames go away.
- **Guest.** `hcmd`'s interface is unchanged. Programs that drive `#C` directly see the new `wait` format and `dir` semantics.

## Security

The guest can run only the host programs the user names, with the scrubbed environment, in host directories it could already see. A named program still runs as the host user with full rights. A command such as `sh` or `python` is equivalent to `'*'`, and the plan says so: names that are interpreters get a caveat. Commands from separate machines in one process are isolated from each other. The process group is killed when the machine ends.

## Done criteria

- [ ] `h9 --host-cmd uname hcmd uname -s` prints the host's kernel name, and `h9 --host-cmd uname hcmd sh -c true` fails with "sh: not allowed".
- [ ] `h9 --host-cmd make --cwd proj --rc 'cd sub; hcmd make'` runs `make` in `proj/sub`.
- [ ] Ctrl-C during `hcmd sleep 100` returns at once, and no `sleep` is left on the host.
- [ ] Integration cases:
  - `host commands are limited to the named ones [host-cmd]`
  - `a host command gets a scrubbed environment [host-cmd]`
  - `dir outside the shared trees is refused [host-cmd]`
  - `a note interrupts a read of a host command's output [host-cmd]`
  - `two machines don't see each other's host commands [host-cmd]`
  - `--strict refuses proc.host without --host-cmd [host-cmd]`
  - the existing `hcmd` and lifetime cases, moved to `[host-cmd]`.

## Implementation

1. `src/hostcmd.zig`: spawn, the pipe reader threads, kill on machine end, per-machine tables. Cover it with unit tests.
2. `src/kern/devhcmd.c`: the device over it, following devhstream. Swap it into devtab for devcmd and drop `hostcmd.c` and the `-Doscmd` renames.
3. Policy: `host_cmds`, `host_cmd_env`, `proc.host`, resolving names at compile time, `--print`'s `host-cmd:` line, and the caveats. Update the CLI flags.
4. `hcmd`: drop the `/proc/$pid/ns` parsing and use `wait`'s new format.
5. Remove `-Dhost-cmd`. Update README, MANUAL, SPEC.md, and `docs/embedding.md`.

## Open issues

- **Windows.** Should names resolve through `PATHEXT`? Should `.cmd` and `.bat` files be refused, since they run through `cmd.exe`?
- **Terminals.** Interactive host programs, such as an editor or `ssh`, need a pty. Is that in scope, or does `hcmd` stay pipe-only?
- **Notes.** Should notes be forwarded as signals (`interrupt` as SIGINT, not a kill) so a host program can clean up?
- **Patterns.** Is a name list enough, or should allowed commands also pin arguments?
- **Limits.** Do `--pids` and `--memory` count host commands?
