---
issue: 89
slug: login-shell
title: h9 as a login shell
status: proposed
created: 2026-11-08
authors: [progrium]
depends: [default-command, host-cmd]
areas: [cli, kern, sandbox, docs, tests]
---

# Proposal: h9 as a login shell

[Sign here by hand once you've reviewed the whole doc and take responsibility for it, as described under Signature in README.md. Tools and agents never add the signature.]

## Abstract

Make rc in h9 usable as the shell a terminal opens on macOS and Linux, without making `h9` itself the account's login shell. h9 gains a second name, `h9sh`, that speaks the POSIX shell contract to the host: `-c`, scripts, and non-interactive runs go to the host's `/bin/sh`, so ssh, scp, rsync, git, and editors keep working, and an interactive login starts `h9 --rc` under a new `shell` profile. Three pieces make that session pleasant: host commands that take over the terminal while they run, so `vim` and `less` work; a `/bin` fallback to the host's `PATH`, so `git` works without typing `hcmd`; and passing chosen host environment variables into the guest. A second Ctrl-C no longer stops a login session's machine.

## Background

What a host login shell has to do: login, sshd, terminal apps, and tmux run it as `-name` (a leading dash) with no arguments, or as `name -c 'command'`. Tools such as scp, rsync, `git` over ssh, VS Code Remote, and editors' `:!` run `$SHELL -c` and expect POSIX `sh` syntax. Interactive programs (editors, pagers, `ssh`, `sudo`, REPLs) expect a terminal on fds 0, 1, and 2, in their own foreground process group.

What h9 does today, measured with a ReleaseSafe `h9` built with `-Demu=unicorn -Dhost-cmd` on an x86\_64 Linux VM with no KVM, against the 9front 11952 386 root (`zig build isoroot`), from a pty:

| Check | Result |
| --- | --- |
| `h9 --rc 'echo hi'`, wall time | 47 ms (emulator) |
| `h9 rc -l -i` to the first prompt | 44–79 ms (emulator) |
| `h9 -c 'echo hi'` | `h9: -c: file does not exist`, exit 127 |
| `h9` with no arguments (as login runs `-h9`) | Usage, exit 2; `argv[0]` is ignored |
| Ctrl-C during `sleep 5` | Interrupts it; rc prompts again |
| A second Ctrl-C within a second | `h9: rc: h9: machine stopped`, exit 130: the session ends |
| Ctrl-Z, `fg`, arrow keys | Ctrl-Z does nothing; arrows arrive as `^[[A`. rc has no job control, and the console has no history. |
| `hcmd uname -sm` | `Linux x86_64` |
| `hcmd tty` | `not a tty` |
| `hcmd vi -c :q` | "Output is not to a terminal", then hangs; later input goes to vim |
| `hcmd sh -c 'env | wc -l'` | 197: devcmd gives host commands h9's whole environment |
| The guest's `/env` | `user`, `home=/usr/$user`, `path=(. /bin)`, and h9's other defaults; no `TERM`, `LANG`, or `PATH` |
| `--host-fs`, then `cd /mnt/term/home/user; hcmd pwd` | `/home/user`: hcmd maps the guest's directory to the host's |

On HVF, `--check` reports a hello in 1.1 ms, so startup is a non-issue on a hypervisor; the native backend ([native-backend](native-backend.md)) would bring Linux hosts without KVM close to that.

Related work:

- [default-command](default-command.md) makes `h9 --rc` with no command line an interactive login rc (`rc -l -i`) on a terminal, reading `/rc/lib/rcmain.local` and `$home/lib/profile`.
- [host-cmd](host-cmd.md) replaces devcmd with a per-machine device whose reads a note can interrupt, allowlists commands with `--host-cmd NAME`, and scrubs their environment. It leaves terminals as an open issue.
- [builtin-root](builtin-root.md) gives h9 a root with no install, so `h9sh` works on a fresh machine.
- [host-binfmt](host-binfmt.md) set the pattern for a second entry point chosen by `argv[0]` and settings read from the environment.

## Proposal

### `h9sh`

A second name for the h9 binary, installed as a link beside it. `main.zig` checks the base name of `argv[0]`, with any leading `-` removed; the dash means a login shell.

- **With arguments other than `-l` or `-i`**, or with no arguments when stdin isn't a terminal, `h9sh` execs the host shell with the same arguments: `$H9SH_SH` if set, else `/bin/sh`. `argv[0]` keeps its leading dash, so the host shell reads its own login files. This covers `-c`, scripts, scp, rsync, `ssh host cmd`, and IDEs that run `$SHELL -lc env`.
- **On a terminal**, with no arguments, `-l`, or `-i`, it runs h9 as `h9 --profile=shell [flags] --rc`: an interactive login rc (default-command).
- **Flags** come from `$XDG_CONFIG_HOME/h9/h9sh` (else `~/.config/h9/h9sh`), one h9 flag per line, `#` comments allowed, then from `H9FLAGS`. A program, `--rc`, `--check`, or `--print` there is refused, as in host-binfmt.
- **It can't lock you out.** If h9 exits 2, 125, or 126 before the first guest process starts (bad flags, no root, no backend), `h9sh` prints h9's message and execs the host shell as for a login. `H9SH_SH` is also how a user who hits a bug gets a working shell back without another account.
- **Nested runs.** A host command started from the guest has `H9_NESTED=1` (host-binfmt's variable); `h9sh` with it set always execs the host shell, so `hcmd bash` and tools that spawn `$SHELL` don't start a machine inside a machine.

The README shows the install: `ln -s h9 h9sh`, adding its path to `/etc/shells`, and `chsh -s`. On macOS the binary must be signed with `h9.entitlements` for HVF.

### The `shell` profile

`--profile=shell` is the default profile with these changes, each shown in `--print`:

- **Files.** The host home is writable and appears at its host path, `/mnt/term$HOME`, as `--writable` paths do; the rest of the host is read-only at `/mnt/term`, as with `--host-fs`. The root keeps its overlay. `$home` is `/mnt/term$HOME`, so `$home/lib/profile` is the user's real file and survives logout.
- **Directory.** The cwd bind is as today, so a terminal opened in a project starts in `/mnt/term/cwd`. `cd /mnt/term/...` reaches any host directory.
- **Network.** `--net enable`.
- **Host commands.** Every host program, as `--host-cmd '*'` in host-cmd's terms, with the login environment rather than the scrubbed one.
- **Environment.** `TERM`, `LANG`, `LC_*`, `EDITOR`, `VISUAL`, `PAGER`, `TZ`, and `SSH_AUTH_SOCK` are copied into the guest's `/env` under their own names (see `--env-pass`).
- **Interrupts.** A second Ctrl-C is an interrupt like the first, not a stop. SIGHUP and SIGTERM still stop the machine.

The profile's caveat says what it is: "the shell profile gives the guest the host user's files, network, and programs; it isn't a sandbox". `--strict` refuses it.

### `--env-pass NAME`

A new repeatable flag that copies the host variable `NAME` into the guest's `/env` if it's set. `NAME` may end in `*` to match a prefix (`LC_*`). `--env` still wins over it. `--print` lists the names under `env-pass:`, without values. Outside the shell profile it's the deliberate way to pass a host value without writing `--env "X=$X"`.

### Host commands on the terminal

When a host command's stdin and stdout are both the guest's console and h9's own stdin is a host terminal, the command gets the terminal itself instead of pipes. h9 stops reading the terminal, starts the command with h9's terminal as fds 0, 1, and 2, in a new process group made the terminal's foreground group, and waits. When it exits or stops, h9 takes the foreground back, restores the terminal modes it had, and resumes reading. Ctrl-C, Ctrl-Z, and window size then belong to the host program and its terminal driver, not to h9: `vim`, `less`, `top`, `ssh`, and `sudo` work as they do from any shell.

In host-cmd's device this is a `ctl` message, `console`, sent before `exec`. The device refuses it unless the conditions above hold, and only one command per machine can hold the console at a time. `hcmd` sends it when its fds 0 and 1 are `/dev/cons`; `hcmd -p` forces pipes. A host program the terminal stops (Ctrl-Z) is resumed with SIGCONT and keeps the console when it's next waited for; rc has no job control, so `hcmd` waits for it again at once.

### Host programs on `/bin`

The host-cmd device serves a directory, `#C/bin`. Walking to a name resolves it on the host `PATH` of h9's environment, subject to the policy's allowlist; reading the file gives an rc script:

```rc
#!/bin/rc
exec hcmd -- NAME $*
```

Listing the directory gives every allowed name found on `PATH`, once, in `PATH` order. The shell profile adds `bind -a '#C/bin' /bin`, after the root's commands, so 9front's `ls` and `cat` win and `git`, `vim`, `make`, and `brew` are found without typing `hcmd`. A user who wants a host tool over a 9front one runs `hcmd ls` or binds `#C/bin` before `/bin` in their profile.

## Rationale

- **Making `h9` itself the login shell.** h9's CLI already uses its arguments, and `-c` scripts written for `sh` don't parse in rc. Every tool that runs `$SHELL -c` would break, and a mistake locks the user out of their account. A separate name that hands everything non-interactive to `sh` keeps those working and keeps h9's CLI unchanged.
- **Running rc on the host instead** (plan9port's rc). That gives a Plan 9-flavoured shell but not h9's namespace, devices, or 9front's programs, which are the point.
- **A pty per host command instead of handing over the terminal.** A pty needs h9 to relay bytes, track window size, and translate signals, and still leaves h9 owning the real terminal's modes. Handing over the real terminal is what every Unix shell does, costs nothing per byte, and gives exact behaviour. A pty is still the answer for host commands whose output is a pipe in the guest; that's left to host-cmd's open issue.
- **A "command not found" hook in rc instead of `#C/bin`.** rc has none, and adding one means changing 9front's rc. A directory union is how Plan 9 already composes `/bin`, works for every program that execs by name, not just rc, and shows up in `ns`.
- **Importing the whole host environment into the guest.** Most host variables mean nothing in Plan 9, and some (`PATH`, `HOME`, `SHELL`) would mislead rc and 9front programs. A short list, extendable with `--env-pass`, is safer and still covers what terminal programs need.
- **Line editing and history in the console.** Plan 9 leaves these to rio, and h9 uses the host terminal's cooked mode. They matter for daily use, but they're separable and don't need any of the above; see Open issues.
- **Job control.** rc doesn't have it, and adding it to rc is out of scope. Host programs get Ctrl-Z through the terminal handoff; guest programs use `&` and `wait`, or a second terminal.

## Compatibility

- **CLI.** `h9sh` is a new entry point; `h9`'s own behaviour is unchanged. `--profile=shell` and `--env-pass` are new. No exit code changes.
- **`Machine.Options`.** `Policy` gains `env_pass: []const []const u8`, `host_console: bool`, and `interrupt_stops: bool` (default true). The shell profile sets them.
- **Sandbox.** The default and tight profiles are unchanged. The shell profile turns on `proc.host` and gives up `env.scrub`, `fs.read.scope`, and `net.outbound`, and says so.
- **host-cmd.** Adds the `console` ctl message and `#C/bin` to the device that proposal defines.
- **Root tree and `third_party/`.** Unchanged.

## Security

The shell profile intentionally gives the guest the host user's files, network, and programs, which is what a shell has. It's opt-in by name, refused by `--strict`, and never the default. `h9sh` adds nothing beyond that: what it runs non-interactively is the host's own `sh`. `#C/bin` exposes only what the host-cmd allowlist already allows. `--env-pass` copies only named variables, and `--print` shows the names. The terminal handoff gives a host program the terminal h9 already had; h9 restores the terminal's modes when it takes it back, so a program that leaves raw mode set doesn't break the session.

## Done criteria

Demo: with `h9sh` as the login shell in a terminal, `ls`, `git status`, `vim README.md`, and `cd /mnt/term/tmp` work, and `ssh localhost 'for i in 1 2; do echo $i; done'` and `rsync` to the host work through the host shell.

Integration cases, using `spawnTerm` where a terminal is needed:

- [ ] `test "h9sh -c runs the host shell [login-shell]"`
- [ ] `test "h9sh with no terminal runs the host shell [login-shell]"`
- [ ] `test "h9sh on a terminal is an interactive login rc [login-shell]"`
- [ ] `test "h9sh falls back to the host shell when h9 can't start [login-shell]"`
- [ ] `test "h9sh with H9_NESTED runs the host shell [login-shell]"`
- [ ] `test "the shell profile's $home is the host home and is writable [login-shell]"`
- [ ] `test "a second Ctrl-C doesn't stop a shell-profile machine [login-shell]"`
- [ ] `test "--env-pass copies named and prefixed host variables [login-shell]"`
- [ ] `test "a host command on the console gets the terminal [login-shell]"`: `hcmd tty` prints a tty path, and `stty size` matches the terminal
- [ ] `test "Ctrl-C reaches a host command on the console as SIGINT [login-shell]"`
- [ ] `test "#C/bin runs host programs by name after the root's [login-shell]"`
- [ ] `test "--strict refuses the shell profile [login-shell]"`

## Implementation

1. `--env-pass` and `Policy.env_pass`, with `--print` and unit cases.
2. `interrupt_stops` in `src/hostsig.zig` and the machine.
3. The `console` ctl message and the terminal handoff in host-cmd's device, and `hcmd -p`.
4. `#C/bin`.
5. The shell profile, its caveat, and `--strict`.
6. `h9sh`: the `argv[0]` check, the config file, the host-shell fallback, and `H9_NESTED`.
7. README (installing as a login shell), MANUAL (a chapter on h9 as your shell), and SPEC.md.

Steps 1 and 2 don't need host-cmd and can land first; with default-command, they already make `h9 --profile=... --rc` in a terminal tab useful.

## Open issues

- **Line editing and history.** Should h9's console reader, when it's a host terminal in cooked mode, offer a small line editor with history (arrows, Ctrl-R), kept in `$home/lib/history`? It'd help every interactive rc, not only this, so it may be its own proposal.
- **Which shell `h9sh` falls back to.** `/bin/sh` is safe but on macOS is a different shell from the user's zsh. Should the config file name it, defaulting to the shell `h9sh` replaced at install?
- **Windows.** There's no login shell in this sense, but Windows Terminal profiles can start `h9 --rc`. Does the terminal handoff work with ConPTY?
- **`#C/bin` listing.** A host `PATH` holds thousands of names. Is listing them all useful, or should the directory list nothing and resolve only on walk?
- **Plan 9's `$path`.** Should the shell profile set `path=(. /bin /mnt/term$HOME/bin)` or leave per-user binds to `$home/lib/profile`?
