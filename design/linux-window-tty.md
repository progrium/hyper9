---
slug: linux-window-tty
title: Linux terminals in 9front windows
status: draft
created: 2026-11-26
authors: [progrium]
depends: [linux-pty]
areas: [linux, kern]
branch: []
---

# Proposal: Linux terminals in 9front windows

## Abstract

A Linux program whose standard input or output is a 9front console file, such as a rio window's, vt's, or a 9/UX Run Command window's `/dev/cons`, gets a real terminal. On its first terminal call on such an fd, h9 connects a `#τ` pty pair to that console. A kernel process of the machine puts the window in raw mode through its `consctl` and copies bytes between the window and the pair's master. The program's fds for that console then move to the pair's slave, which becomes its controlling terminal. devpty's line discipline handles echo, line editing, and signals. The window size comes from vt's `/env/LINES` and `/env/COLS`, or from `/dev/wctl` and the font. A resize becomes `TIOCSWINSZ` and `SIGWINCH`. When the last program using the pair closes it, the window goes back to cooked mode. vi, less, htop, fzf, and readline then work in vt under rio, in 9/UX, and in any other 9front terminal, with no change to rio, vt, or the Linux programs.

## Background

- **Terminals only work from the host.** In the Linux personality, `isatty` and the termios ioctls succeed only on h9's own console (`#c` and `#y`), and only when h9's stdin and stdout are host terminals (`console_tty`, spec/abi-linux.md, "Roots, environment, and console"). That console has one termios per machine (`console_term` in src/abi/linux/sys.zig), and `TCSETS` switches the host terminal through `kern.setConsoleMode`. A window's `/dev/cons` is a file served by rio (or vt, or libux), so every terminal ioctl on it returns `ENOTTY`.
- **What that breaks.** On Nov 26, 2026, 9/UX ran under h9 at de11fc3 with Alpine 3.22 on `#L`, driven headless through `/dev/kbdin`. Line-oriented Linux programs worked in Run Command: busybox, `apk`, pipes in both directions with 9front programs, `sh -i`, and Delete interrupting a Linux `sleep`. Anything that needs a tty failed. `tty` printed "not a tty", `stty size` failed, and busybox vi printed its escape sequences as text. In a `vt -x` window, vi drew correctly, but the window stayed in cooked mode, so vi got keys a line at a time and Esc never reached it.
- **linux-pty left this out on purpose.** [linux-pty](epoch-0/linux-pty.md) built `#τ` pairs with Linux's `N_TTY` line discipline in devpty.c, and host masters for embedders (src/hostpty.zig: a kernel process that opens `#τ/ptmx` and pumps the master). Its Rationale says "9front's `vt` and rio windows are its own terminals. This proposal doesn't add anything for the 9front side." This proposal is that side.
- **What 9front terminals give us.** rio's and vt's `consctl` take `rawon` and `rawoff`, and both reset raw mode when the `consctl` fd that set it closes. vt also takes `winchon` and `winchoff`. vt runs its child in vt's environment group and keeps `/env/TERM`, `/env/LINES`, `/env/COLS`, `/env/XPIXELS`, `/env/YPIXELS`, and `/env/WINCH`, a counter it increments on every resize, current. With `winchon` set, it also posts `interrupt` to the child's note group after a resize. A Linux program's environment is already the machine's `/env`, so `TERM` from vt already reaches it. A plain rio window has no `TERM` and doesn't interpret escape sequences, but `/dev/wctl` gives its rectangle.

## Proposal

### Which fds are window consoles

A **window console** is an fd whose path (`fd2path`) ends in `/cons`, with a `consctl` beside it, on any device other than `#c` and `#y`. In practice that's a file served by rio, vt, libux, or any other 9front terminal. h9's own console keeps the behavior it has today, including `console_tty` and `kern.setConsoleMode`.

### Connecting a window console

The first terminal ioctl on a window console makes the connection. That's `TCGETS` (which is what `isatty` calls), `TCSETS` in any form, `TIOCGWINSZ`, `TIOCGPGRP`, or `TIOCSCTTY`. Programs that never ask, such as `cat` and `grep` in a pipeline, are never connected, and the window stays as it is. Connecting does the following:

1. h9 finds or makes the **bridge** for that console. There is one bridge per open console, identified by its channel (`type`, `dev`, `qid.path`, and mount), and every Linux process on the console shares it.
2. To make a bridge, a kernel process of the machine opens `#τ/ptmx`, sets the slave's window size (below), and opens the sibling `consctl` and writes `rawon`. It keeps that `consctl` fd open for as long as the bridge lives, because the server drops raw mode when it closes. It then runs two loops, built the way hostpty.zig's control and reader processes are. One reads the window's `cons` and writes the bytes to the master. The other reads the master and writes the bytes to the window's `cons`.
3. Every fd in the calling process's fd table that refers to that console is replaced by a dup of the slave, so fds 0, 1, and 2 usually move together. If the caller leads a session (or is the machine's first Linux process on that console), the slave becomes its controlling terminal, as `TIOCSCTTY` would make it, and its process group becomes the foreground group. Otherwise the pair joins the caller's session as its terminal.
4. The ioctl then runs on the slave, as for any `#τ` fd.

From then on, the program and its children see `/dev/pts/N`. That covers `ttyname`, `/dev/tty`, `/proc/self/fd`, and job control, with everything else exactly as linux-pty specifies. In raw mode, rio and vt pass every key as typed, so ^C, ^Z, ^\, Esc, and arrow keys arrive as bytes, and devpty's `ISIG` turns them into signals for the foreground group.

### Reading without stealing input

The window reader loop reads `cons` only while a slave read is waiting, or while canonical mode has a partial line to echo. devpty gains a call that reports a waiting slave reader and wakes the bridge when one starts. This way, a Linux program left running in the background with `&` doesn't take keys that rc, sharing the same window, is waiting for.

### Window size and SIGWINCH

The bridge sets the pair's size when it starts and again after each resize:

- If `/env/LINES` and `/env/COLS` are set in the console's environment group, which vt keeps current, h9 uses them, with `XPIXELS` and `YPIXELS` for the pixel fields.
- Otherwise h9 reads the window's rectangle from the `wctl` beside `cons` and divides by the character size of `$font`, less rio's border and margin. If neither works, the size is 80x24.

Resize detection follows vt's protocol. The bridge writes `winchon` on its `consctl`, and vt then posts `interrupt` to the note group. h9's note-to-signal mapping (src/abi/linux/signal.zig) checks `/env/WINCH` before turning `interrupt` into `SIGINT` for a process whose controlling terminal is a bridged pair. If the counter advanced since the bridge last read it, the note is consumed, and the bridge runs `TIOCSWINSZ`, which sends `SIGWINCH` to the foreground group as linux-pty does. In a plain rio window, the `wctl` reader loop blocks on `wctl` reads, which return when the window changes.

### TERM

A Linux program gets `TERM` from `/env/TERM` as it does today. When a bridged console's environment has no `TERM`, which is the case for plain rio and Run Command windows, h9 sets `TERM=dumb` for Linux processes on it. Programs then line-edit, prompt, and stop colouring, instead of printing escape sequences that the window shows as text. Full-screen programs need a terminal emulator: vt, or a VT mode in the 9/UX console (see Open issues).

### Disconnecting

When every slave fd has closed, the master reads `EIO`. The bridge then writes `winchoff` and `rawoff`, closes `consctl`, closes the master, and exits. The window is back in cooked mode for rc or whatever reads it next. If the window's `cons` hangs up (the window was deleted), the bridge closes the master, so the slave is hung up and its foreground group gets `SIGHUP`, as for any pty master that closes.

### 9front programs on a bridged console

A 9front program exec'd from a bridged Linux process inherits the slave as its fds 0, 1, and 2 and reads lines from it in canonical mode, as from a pipe. A 9front program that opens `/dev/cons` by name still reaches the window directly, and while the bridge holds the window raw, it reads raw keys. Linux programs rarely run such programs in the middle of a session, and Open issues lists a fix.

## Rationale

- **A pty pair rather than termios on the window.** The alternative is to keep a termios per window console and map `ICANON` and `ECHO` onto `rawon` and `rawoff`, as `TCSETS` does for h9's console today. A 9front `cons` has only two modes, though. Cooked means rio's line editing with echo, and raw means no echo and no editing. There's no `ECHO` without `ICANON`, no echo-off with line editing (`read -s`), no `VMIN` or `VTIME`, no `ISIG` in raw mode, and no foreground group. All of that would have to be written again next to the console. devpty.c already has every piece, along with the controlling-terminal and job-control rules, so a bridge reuses them unchanged.
- **Connecting on the first terminal call rather than at exec.** Connecting at exec would put the window in raw mode for every Linux program whose stdio is a window, including `grep` reading a line you type, and it would take away rio's own line editing for no reason. Connecting on the first terminal call costs nothing for programs that never call one.
- **Replacing the fds rather than proxying the console.** A proxy would have to make every console read and write through the personality honour the pair's termios, while `poll`, `epoll`, `FIONREAD`, and `/proc/self/fd` still saw the console. Dup'ing the slave over the fds puts the process on an ordinary `#τ` fd, so the existing paths apply.
- **Using vt's environment and `winchon` rather than a new protocol.** vt already publishes its size this way, and 9front's ssh uses `/env/WINCH` the same way. Other 9front terminals can do the same, which 9/UX's console could adopt.
- **A guest tool instead.** A `script`-like 9front command could open a pty, set the window raw, and pump bytes, and it would work today with no change to h9. It would need to be run by hand before each program, though, and it couldn't hand the controlling terminal to the program's session. It's still useful as a stopgap and as a way to test the bridge's loops.
- **The host's ptys.** These were rejected in linux-pty for the same reasons: they leave the sandbox's view, and they don't exist on Windows or the browser host.

## Compatibility

- **CLI and `Machine.Options`:** no changes.
- **h9's own console:** unchanged. The bridge applies only to window consoles.
- **Linux programs on a window console:** `isatty`, `tcgetattr`, and `TIOCGWINSZ` now succeed where they returned `ENOTTY`. A program that checks `isatty` before colouring sees a terminal, but it also sees `TERM=dumb` unless the window is a vt, so output to plain rio windows stays plain.
- **rio, vt, and 9/UX:** no changes. While a bridge holds the window raw, rio's line editing and mouse selection of the input line are replaced by the Linux line discipline. That's what you'd expect while a Linux program runs, and it ends when the program does.
- **`third_party/`:** no changes.

## Security

The bridge reaches nothing the program couldn't already reach. It opens the `consctl` and `wctl` beside a `cons` the program already holds, in the program's own namespace, and a `#τ` pair, which is machine-local. The pty cap from linux-pty covers the bridges. No host resources are involved.

## Done criteria

Integration cases on the headless screen, tagged `[linux-window-tty]`, with the 9front root and the Alpine root. Each case runs rio with a vt window (or a plain window) and types through `/dev/kbdin`.

- [ ] `test "isatty is true on a vt window's cons, and tty prints /dev/pts/0 [linux-window-tty]"`
- [ ] `test "a Linux program in raw mode reads Esc and arrow keys as bytes [linux-window-tty]"`
- [ ] `test "read -s in ash reads a line without echoing it [linux-window-tty]"`
- [ ] `test "Ctrl-C in raw mode sends SIGINT to the foreground group [linux-window-tty]"`
- [ ] `test "stty size follows vt's LINES and COLS, and a resize sends SIGWINCH [linux-window-tty]"`
- [ ] `test "a plain rio window gets TERM=dumb and its size from wctl [linux-window-tty]"`
- [ ] `test "the window is back in cooked mode for rc after the program exits [linux-window-tty]"`
- [ ] `test "a background Linux job doesn't take rc's input [linux-window-tty]"`
- [ ] `test "cat and grep in a pipeline leave the window cooked [linux-window-tty]"`
- [ ] Demo: busybox vi in `vt -x` under rio edits and saves a file, and htop draws and quits on `q`, in a 9/UX session.

## Implementation

1. devpty.c: a call that reports whether a slave read is waiting, and wakes a waiter when one starts.
2. The bridge: a kernel process per window console, with its window reader, master reader, and size loops, built the way hostpty.zig's processes are, in src/machine.zig.
3. sys.zig: window console detection, connecting on the first terminal ioctl, the fd swap, the controlling terminal, and `TERM=dumb`.
4. signal.zig: the `/env/WINCH` check before `interrupt` becomes `SIGINT`.
5. The headless cases, and the "Roots, environment, and console" section of spec/abi-linux.md.

## Open issues

- **9front programs that open `/dev/cons` by name under a bridge.** h9 could bind the slave over `/dev/cons` in a bridged process's namespace when it execs a 9front program. That needs `consctl` semantics on a pty, either served by devpty or mapped onto termios.
- **A VT mode for 9/UX's Run Command.** With this proposal, a Linux program in Run Command gets a terminal with `TERM=dumb`. Full-screen programs there would need libux's console to interpret escape sequences and publish `LINES`, `COLS`, and `WINCH` the way vt does. That's 9/UX's work, not h9's.
- **rio's margins.** Working out the character size from `wctl` and `$font` can be off by a column if rio's border width changes. Asking terminals to publish `LINES` and `COLS` avoids the guess.
- **Two machines on one window.** A window served over 9P to a second machine would get a bridge in each machine. Only one can hold raw mode sensibly, and the second could fall back to `ENOTTY`.
