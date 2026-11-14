---
slug: linux-pty
title: Linux pseudoterminals
status: draft
created: 2026-11-14
authors: [progrium]
depends: [linux-personality]
areas: [kern, linux]
branch: []
---

# Proposal: Linux pseudoterminals

## Abstract

Serve Linux pseudoterminals: `/dev/ptmx` and `/dev/pts/N` in the Linux view, with a pty pair device in the kernel and the pty ioctls in the Linux personality. The first step is a raw pty, in which termios is stored but doesn't change the data. That's enough for Nix, which opens a pty for every build's log, and for `script` and node-pty in raw mode. The second step is a line discipline (canonical mode, echo, `ISIG`, and `SIGWINCH`) for shells, tmux, and screen inside a pty.

## Background

A Linux program gets a pty by opening `/dev/ptmx` (musl's and glibc's `posix_openpt`). It then asks for the slave's number with `TIOCGPTN` (`ptsname`), unlocks it with `TIOCSPTLCK` (`unlockpt`), and opens `/dev/pts/N`. Bytes written to the master are read from the slave, and the other way round, through the terminal's line discipline. `grantpt` is a no-op on musl and checks `/dev/pts/N`'s ownership on glibc.

h9 has no ptys. `/dev` in the Linux view (devlinux, [linux-personality](linux-personality.md)) has no `ptmx` and no `pts`, so `posix_openpt` fails with `ENOENT`. Everything that needs one fails outright: tmux, screen, `script`, `expect`, sshd's sessions, Python's `pty` and `pexpect`, node-pty (used by terminal emulators and editors' built-in terminals), and Nix. Nix's builder opens a pty to capture every build's log and fails with "opening pseudoterminal master" before the builder starts. Nix builds its profiles and shell environments as local derivations, so this blocks `nix profile install`, `nix-env -i`, and `nix develop`, not just source builds.

The console already has most of a terminal. The Linux personality keeps one termios per machine for it. `TCSETS` with `ICANON` off turns on the console's raw mode, `ECHO` sets its echo, and with `ISIG` set the console turns `VINTR`, `VQUIT`, and `VSUSP` into `SIGINT`, `SIGQUIT`, and `SIGTSTP` for the foreground process group (linux-personality, "Terminal" and "Job control"). A pty needs the same things on a pair of queues instead of the host terminal.

A spike for Nix (Nov 13, 2026) put a Plan 9 pipe in for each pty, bound under `/tmp`, with `TIOCGPTN` and a fake termios. Nix's builds got past the pty that way, which showed that raw mode is all Nix needs. A pipe can't hold a termios, a window size, or a foreground group, though, and the bind it left behind was visible in the namespace.

## Proposal

**A pty device.** A new kernel device, `#τ` (src/kern/devpty.c), serves pty pairs:

- `#τ/ptmx` is a clone file. Each open makes a new pair and returns its master, as `#|` does for pipes.
- `#τ/N` is pair N's slave. Opening it while the master is open and the pair is unlocked returns the slave. A locked pair, or one whose master has closed, gives an error.
- A pair has two queues, one in each direction, each 64 KiB, which is Linux's `N_TTY` buffer size. When every slave fd closes, a master read returns EOF, and Linux programs see `EIO`. When the master closes, slave reads return EOF, slave writes fail, and the foreground group gets `SIGHUP`.
- A pair keeps its termios, window size, foreground process group, session, and lock state. A `ctl` file in the pair's directory (`#τ/N/ctl`), or a kernel call from the personality, reads and writes them.
- Pair numbers are per machine, start at 0, and are reused once both sides close.

**The Linux view.** devlinux serves `/dev/ptmx` as `#τ/ptmx` and `/dev/pts` as `#τ`'s directory, so `/dev/pts/N` is `#τ/N`. `stat` shows them as character devices, with major 5, minor 2 for `ptmx`, and major 136, minor N for the slaves, as Linux does, since glibc's `grantpt` and `ttyname` check those numbers. `/dev/tty` in a process whose controlling terminal is a pty opens that pty's slave.

**The ioctls,** in src/linux/sys.zig, on an fd of `#τ`:

| ioctl | On |
| --- | --- |
| `TIOCGPTN`, `TIOCSPTLCK`, `TIOCGPTPEER` | the master |
| `TCGETS`, `TCSETS`, `TCSETSW`, `TCSETSF`, and the `termios2` forms | either side, on the pair's termios |
| `TIOCGWINSZ`, `TIOCSWINSZ` | either side. A size change sends `SIGWINCH` to the foreground group |
| `TIOCSCTTY`, `TIOCNOTTY`, `TIOCGPGRP`, `TIOCSPGRP`, `TIOCGSID` | the slave, on the pair's session and foreground group |
| `FIONREAD`, `TCFLSH`, `TIOCOUTQ`, `TCSBRK` | either side |

`isatty` is true on both sides, as on Linux. `poll`, `select`, and `epoll` see the queues, since they're kernel queues.

**Step 1: raw.** The termios is stored and returned, but data passes through unchanged in both directions. This is what `cfmakeraw` asks for, which covers Nix, `script -q`, `expect`, and node-pty in raw mode.

**Step 2: the line discipline.** The pair's termios is applied as Linux's `N_TTY` does:

- input: `ICRNL`, `INLCR`, and `IGNCR`. `ICANON` line editing with `VERASE`, `VKILL`, `VWERASE`, and `VEOF`, with `VMIN` and `VTIME` when it's off. `ECHO`, `ECHOE`, `ECHOK`, `ECHONL`, and `ECHOCTL`.
- output: `OPOST` with `ONLCR`.
- `ISIG`: `VINTR`, `VQUIT`, and `VSUSP` written to the master become `SIGINT`, `SIGQUIT`, and `SIGTSTP` for the pair's foreground group, through the same path the console uses.

The console's own line handling stays as it is. It's the host terminal's, and h9 only switches it.

## Rationale

- **A kernel device rather than pipes.** A pipe pair carries bytes, but nowhere to keep a termios, a window size, or a foreground group, and nothing to reopen by number. That's why the spike needed a bind and a fake termios. A device keeps the pair's state with its queues, and makes `poll`, notes, and close behave like any other kernel file.
- **In the kernel, not in Zig.** The queues need the kernel's sleep and wakeup, `poll`, and interruption by notes, and step 2's line discipline has to run when bytes are written, whichever process writes them. That's devpipe's shape. The ioctls stay in the personality, since they're Linux's interface.
- **Raw first.** Raw mode has no policy in it, and it unblocks Nix and most programs that drive a child through a pty. The line discipline is most of the work and most of the risk, and it ties into job control. Splitting the steps lets the first land without waiting for the second.
- **9front programs.** `#τ` is a kernel device, so a 9front program could open it too, but nothing in 9front uses Linux ptys, and 9front's `vt` and rio windows are its own terminals. This proposal doesn't add anything for the 9front side.
- **The host's ptys.** h9 could open a real pty on the host for each pair. That would put a host fd in each pair, leave the sandbox's view of the guest, and fail on Windows and the browser host. Ptys are guest state, like pipes.

## Compatibility

There are no CLI or `Machine.Options` changes. The Linux view gains `/dev/ptmx` and `/dev/pts`. `#τ` is new, and the device mask (`--profile`) covers it like other devices. It's allowed in the default profile, since it reaches nothing outside the machine. Nothing in `third_party/` changes.

## Security

A pty pair is kernel memory and two queues inside one machine. It reaches nothing on the host, and other machines can't see it. Pairs count against the kernel's allocations like pipes do. A cap on open pairs per machine (Linux's `kernel.pty.max` defaults to 4096) keeps a guest from making unbounded numbers of them.

## Done criteria

Integration cases, tagged `[linux-pty]`, with the Alpine root:

- [ ] `test "posix_openpt, grantpt, unlockpt, and ptsname give an open slave [linux-pty]"`: a small C program opens a pair, writes to the master, reads from the slave, and the other way round.
- [ ] `test "the master reads EOF once the slave closes [linux-pty]"`
- [ ] `test "Python's pty.spawn runs a command in a pty [linux-pty]"`: `python3 -c 'import pty; pty.spawn(["tty"])'` prints `/dev/pts/0`, with the workloads root.
- [ ] `test "a raw pty passes bytes unchanged [linux-pty]"`, after `cfmakeraw`.
- [ ] `test "TIOCSWINSZ sends SIGWINCH to the foreground group [linux-pty]"`
- [ ] Demo: the static Nix from the Nix spike builds a `derivation { builder = "/bin/sh"; … }` with `sandbox = false`, and `nix profile install nixpkgs#hello` makes a profile.

Step 2:

- [ ] `test "a canonical pty edits lines and echoes [linux-pty]"`
- [ ] `test "Ctrl-C written to the master interrupts the foreground group [linux-pty]"`
- [ ] Demo: `tmux new -d 'sleep 1; echo hi > /tmp/x'` runs, and `tmux capture-pane` shows the shell.

## Implementation

1. devpty.c: pairs, the clone file, the queues, close and hangup, and a ctl for the pair state. Register it in devtab.c.
2. devlinux: `/dev/ptmx` and `/dev/pts`, with their `stat` device numbers.
3. sys.zig: the ioctls on `#τ` fds, controlling terminals (`TIOCSCTTY`, `setsid`, and `/dev/tty`), and `isatty`.
4. The step 1 cases and the Nix demo.
5. Step 2: the line discipline in devpty.c, sharing the signal path with the console's `ISIG` handling.

## Open issues

- Whether step 2 should be its own proposal, as README.md suggests for parts that finish at different times. It's kept here for now so the device's state is designed once.
- How `/dev/tty` should pick between the console and a pty for a process that has neither as its controlling terminal.
- Whether `TIOCSTI` should be served at all. Linux 6.2 and later make it optional, because it lets a program inject input.
