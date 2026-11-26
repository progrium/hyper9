---
slug: linux-window-tty
title: Linux terminals in 9front windows
status: draft
created: 2026-11-26
authors: [progrium]
depends: [linux-pty, linux-threads]
areas: [linux, kern]
branch: []
---

# Proposal: Linux terminals in 9front windows

## Abstract

A Linux program whose standard input or output is a 9front console file gets a real terminal. That covers a rio window's `/dev/cons`, vt's, and a 9/UX Run Command window's. On the program's first terminal call on such an fd, h9 connects a `#τ` pty pair to that console, through a **bridge** owned by the machine's kernel. The bridge puts the window in raw mode through its `consctl`, holds that `consctl` open, and copies bytes between the window and the pair's master. It reads the window only while a program on the slave is waiting for input. The program's fds for that console move to the pair's slave, which becomes its controlling terminal, so devpty's line discipline handles echo, editing, ^C, ^Z, and the rest exactly as in any pty.

The size comes from the terminal's `/env/LINES` and `/env/COLS`. A resize arrives as the terminal's `winchon` note, which h9 matches against `/env/WINCH` and turns into `TIOCSWINSZ` and `SIGWINCH` instead of `SIGINT`. A window without `TERM`, such as a plain rio window, gets `TERM=dumb`. When the last program using the pair closes it, the bridge returns the window to cooked mode. vi, less, htop, fzf, top, and readline then work in vt, in 9/UX's Run Command, and in any 9front terminal that follows vt's conventions, with no change to rio, vt, 9/UX, or the Linux programs.

## Background

- **Terminals only work from the host.** In the Linux personality, `isatty` and the termios ioctls succeed only on h9's own console (`#c` and `#y`), and only when h9's stdin and stdout are host terminals (`console_tty`, spec/abi-linux.md, "Roots, environment, and console"). `ioctl` in src/abi/linux/sys.zig returns `ENOTTY` for any other fd that isn't a `#τ` pty: `if (!isConsole(fd) or !p.console_tty) return -E.NOTTY`. The console has one termios per machine (`console_term`), and `TCSETS` switches the host terminal through `kern.setConsoleMode`. A window's `/dev/cons` is a file that rio, vt, or libux serves over a mount, so it's never `isConsole`.
- **What that breaks.** On Nov 26, 2026, 9/UX ran under h9 at de11fc3 with Alpine 3.22 on `#L`, driven headless through `/dev/kbdin`. Line-oriented Linux programs worked in Run Command: busybox, `apk`, pipes in both directions with 9front programs, `sh -i`, and Delete interrupting a Linux `sleep`. Anything that needs a tty failed. `tty` printed "not a tty", `stty size` failed, and busybox vi printed its escape sequences as text. In a `vt -x` window vi drew correctly, but the window stayed in cooked mode, so vi got keys a line at a time and Esc never reached it.
- **linux-pty left this out on purpose.** [linux-pty](epoch-0/linux-pty.md) built `#τ` pairs with Linux's `N_TTY` line discipline in src/kern/devpty.c. It also built host masters for embedders (src/hostpty.zig, `ptyServerMain` in src/machine.zig): kernel processes of the machine that open `#τ/ptmx` and pump the master. Its Rationale says "9front's `vt` and rio windows are its own terminals. This proposal doesn't add anything for the 9front side." This proposal is that side.
- **What 9front terminals provide.** rio, vt, and Run Command all serve `cons` and `consctl` beside it.
  - `consctl` takes `rawon` and `rawoff`. Each of the three drops raw mode when the `consctl` fd that set it is closed (rio's `xfidclose`, vt's `fsdestroyfid`, and Run Command's console), so whoever wants raw mode has to hold `consctl` open.
  - In raw mode, keys are passed as typed, Delete included. rio adds raw keys to the read queue without posting a note when the insertion point is at the end (`wkeyctl` in rio's wind.c). vt sends Delete as its escape sequence in raw mode instead of posting `interrupt` (main.c). So in raw mode ^C, ^Z, ^\, Esc, and Delete reach the reader as bytes.
  - vt and Run Command share their environment group with the program they run. They keep `TERM`, `LINES`, `COLS`, `XPIXELS`, and `YPIXELS` current there, and they count resizes in `WINCH`. After `winchon` is written to `consctl`, they post `interrupt` to the note group after each resize, and the reader tells a resize from a keyboard interrupt by `WINCH` having changed. 9front's ssh uses the same protocol. Run Command has followed it since 9ux's "Run Command is an xterm" change (progrium/9ux#29), which gives its console an `xterm-256color` emulator with an alternate screen.
  - A plain rio window has no `TERM` and interprets no escape sequences. Its `wctl` gives the window's rectangle, but rio lets only one fd at a time open `wctl` for reading (`Einuse`), and a read after the first blocks until the window changes.
  - A Linux program's environment is built from the machine's `/env` when it execs, so `TERM` from vt or Run Command already reaches it.
- **A user-space spike.** On Nov 26, 2026, a static Linux program, `wtty`, did a bridge's job by hand. It ran as `wtty prog args... >[3]/dev/consctl`: it wrote `rawon` and `winchon` to fd 3, opened `/dev/ptmx`, ran the program on the slave as a session leader with it as the controlling terminal, and pumped the window's `cons` to and from the master. Under h9 at de11fc3, in Run Command and in `vt -x` windows under 9/UX's rio:
  - `tty` printed `/dev/pts/0`, `stty size` gave the window's `LINES` and `COLS` (41 114), and `TERM` was `xterm-256color`.
  - busybox vi inserted text, took Esc, opened a line, and saved with `:wq`. busybox top drew and quit on `q`. `read -s` read a password without echoing it.
  - ^C typed as a byte became `SIGINT` through devpty's `ISIG`, and an `INT` trap in ash caught it. A resize ran ash's `WINCH` trap, and `stty size` then gave the new width.
  - Three things went wrong, and the design below addresses each.
    1. **Stolen keys.** The text typed after a program exited lost its first several characters, because they went to the bridge's outstanding read on `cons`. h9's `poll` counts 9P files as always ready (spec/abi-linux.md, "Readiness"), so a user-space bridge can't wait for input without a read in flight, and the read stays in flight after its program is done.
    2. **Resize notes reach everyone.** The `interrupt` from `winchon` goes to the whole note group, which includes the program on the slave as well as the bridge. A resize fired ash's `INT` trap as well as its `WINCH` trap.
    3. **Counting notes.** One resize, which advanced `WINCH` once, delivered two interrupts to the bridge. With "WINCH unchanged means a real interrupt", the second turned into a spurious ^C. The bridge had two threads, and the note likely reached each.
  - Separately, a Linux program with a `SIGINT` handler that was in the background under rc died when `interrupt` was written to its `/proc/N/notepg`, on both the sud engine and the emulator, where on Linux it would have run the handler. That wasn't reproduced in the foreground under the bridge, where the handler ran. It's recorded under Open issues.

## Proposal

### Window consoles

A **window console** is an fd that meets three conditions. Its path (`fd2path`) ends in `/cons`. A `consctl` exists beside it in the same directory of the process's namespace. And its channel's device is neither `#c` nor `#y`. In practice that means a file served by rio, vt, libux, or another 9front terminal. h9's own console keeps the behaviour it has today, including `console_tty` and `kern.setConsoleMode`.

A window console's **identity** is its channel's `type`, `dev`, `qid.path`, and mount. Two fds that are the same window have the same identity, whatever path they were opened by.

### Connecting

The first terminal ioctl on a window console makes the connection. That's `TCGETS` (which `isatty` and `tcgetattr` call), `TCSETS` in any of its forms, `TIOCGWINSZ`, `TIOCGPGRP`, `TIOCSPGRP`, or `TIOCSCTTY`. Any other ioctl on a window console still returns `ENOTTY`. Programs that never ask, such as `cat` and `grep` in a pipeline, are never connected, and the window stays cooked.

Connecting does the following:

1. h9 finds the bridge for the console's identity, or makes one. There is at most one bridge per window console in a machine, and every Linux process on that console shares it.
2. To make a bridge, the machine's pty server starts a kernel process, as `ptyServerMain` does for a host master. That process opens `#τ/ptmx` and unlocks the slave at the window's size (below). In the calling process's namespace, it opens the `cons` and `consctl` beside the fd's path, writes `rawon` and then `winchon` to `consctl`, and keeps that fd open for the bridge's whole life. Opening by path in the caller's namespace reaches the same window the caller's fd does. If any step fails, the ioctl returns `ENOTTY`, as it does today, and nothing changes.
3. In the calling process's fd table, every fd whose channel has the console's identity is replaced by a dup of the slave, with its `O_CLOEXEC` and status flags kept. That's usually fds 0, 1, and 2 together. The fd table is the process's, so threads that share it (`CLONE_FILES`) see the change too. Fds in other processes, including the 9front shell that started the program, are untouched.
4. If the caller has no controlling terminal, the slave becomes its controlling terminal, as `TIOCSCTTY` makes it (linux-pty's session rules), and the caller's process group becomes the pair's foreground group. If the caller already has a controlling terminal that isn't this console, the fds are still replaced, but the controlling terminal stays as it was.
5. The ioctl then runs on the slave, as on any `#τ` fd.

From then on the program and the children it forks see `/dev/pts/N`. That covers `ttyname`, `/dev/tty`, `/proc/self/fd`, job control, `poll`, `epoll`, `FIONREAD`, and the line discipline, all exactly as linux-pty specifies. In raw mode every key reaches the master as a byte, so devpty's `ISIG` turns ^C, ^Z, and ^\ into `SIGINT`, `SIGTSTP`, and `SIGQUIT` for the foreground group, and Esc and arrow keys pass through as the escape sequences the terminal sends.

A second Linux process that connects to the same console later, such as one started by rc after the first has exited, shares the existing bridge if it's still alive, and starts a new one otherwise. A Linux process started from a bridged program inherits the slave fds, so it doesn't connect again.

### The bridge's loops

A bridge has three kernel processes, built the way hostpty.zig's control process and reader are.

- **The input loop** reads `cons` and writes what it reads to the master. It reads only while devpty reports that a read is waiting on the slave, or while canonical mode has a partial line on the master side that's still being edited. Otherwise it blocks on devpty, not on `cons`. devpty gains `h9_pty_wantinput(fd)`, which blocks until a slave read starts or the pair closes, and reports which one happened. With this rule, a Linux job left running in the background with `&` doesn't take the keys rc is waiting for, and the window isn't read after the last program on the slave has stopped reading.
- **The output loop** reads the master and writes what it reads to `cons`. In raw mode, devpty's `OPOST` with `ONLCR` gives the terminal `\r\n`, which vt and Run Command expect. A write that fails because the window has gone ends the bridge (see Disconnecting).
- **The note loop** handles resizes (below).

When the input loop is blocked in a read on `cons` and the pair closes, the bridge flushes that read (9P `Tflush`) before it writes `rawoff`. Bytes that rio has already queued as the answer to the read are passed to the master if the pair is still open, and dropped otherwise. That's at most the keys typed in the moment the program exits.

### Window size

The bridge sets the pair's size when it starts, and again after each resize:

- If the console's environment group has `/env/LINES` and `/env/COLS`, which vt and Run Command keep current, those are the rows and columns, with `XPIXELS` and `YPIXELS` as the pixel fields. They're read from `/env` in the namespace the bridge was started in, which is the program's.
- Otherwise, if `wctl` beside `cons` can be opened and read, the bridge reads the rectangle once and closes `wctl` again, because rio allows only one reader. It then divides by the character size of `/env/font`, after taking off rio's border and text margin. Without either, the size is 80x24.

### Resizes and notes

A terminal following vt's protocol posts one `interrupt` to the note group for each increase of `WINCH`. Every Linux process on the bridged console is in that group, so the note reaches the program and its children as well as the bridge. In raw mode, the keyboard doesn't post notes (Background), so an `interrupt` while the bridge holds raw mode is a resize, a 9front program's `postnote`, or a terminal's own "Interrupt" command, such as Run Command's Shell menu.

h9 handles the note in two places:

- **The note loop** keeps `handled`, the `WINCH` value it last acted on. When it's woken by an `interrupt`, it reads `WINCH`. If `WINCH` is greater than `handled`, it sets `handled` to `WINCH`, re-reads the size, and runs `TIOCSWINSZ` on the master if the size changed. linux-pty's `TIOCSWINSZ` sends `SIGWINCH` to the foreground group. The bridge's note loop is a kernel process, so it receives the note without being a Linux process.
- **The note-to-signal path** in src/machine.zig (`lsig.noteSignal`) treats `interrupt` specially for a Linux process whose controlling terminal is a bridged pair. Each such pair keeps `pending`, the number of resize notes not yet consumed, which is `WINCH` less `consumed`. When `interrupt` reaches the process, and `pending` is above zero, h9 consumes one and drops the note. Otherwise the note becomes `SIGINT`, as it does today. Counting is per process, not per thread: a group note that reaches several threads of one Linux process is counted once, the way linux-threads delivers a process's signal once.

The process-level count is what makes the spike's two failures go away. The program isn't interrupted by a resize, and a resize that one process sees through two threads isn't counted as two.

### TERM

A Linux program gets `TERM` from `/env/TERM`, as it does today. When a bridged console's environment has no `TERM`, as in a plain rio window, h9 sets `TERM=dumb` in the environment of Linux programs that exec on the slave. Programs then line-edit, prompt, and stop colouring, instead of sending escape sequences that the window would show as text. Full-screen programs need a terminal emulator: vt, or 9/UX's Run Command.

### Disconnecting

When every slave fd has closed, the master reads `EIO`, and the bridge ends. It writes `winchoff` and `rawoff`, closes `consctl`, `cons`, and the master, and exits. The window is back in cooked mode for rc or whatever reads it next. A bridge never outlives its pair.

If the window's `cons` hangs up, because the window was deleted or its terminal exited, the bridge closes the master. The slave hangs up, and its foreground group gets `SIGHUP`, as for any pty master that closes.

### 9front programs on a bridged console

A 9front program exec'd from a bridged Linux process inherits the slave as its fds 0, 1, and 2, and reads lines from it in canonical mode, as from a pipe. A 9front program that opens `/dev/cons` by name still reaches the window directly. While the bridge holds the window raw, it reads raw keys there and competes with the input loop for them. Linux programs rarely run such programs in the middle of a session, and Open issues has a fix.

## Rationale

- **A pty pair rather than termios on the window.** The alternative is to keep a termios per window console and map `ICANON` and `ECHO` onto `rawon` and `rawoff`, as `TCSETS` does for h9's console today. A 9front `cons` has only two modes, though. Cooked means the terminal's own line editing with echo, and raw means no echo and no editing. There's no `ECHO` without `ICANON`, no echo-off with line editing (`read -s`), no `VMIN` or `VTIME`, no `ISIG` in raw mode, and no foreground group. All of that would have to be written again next to the console. devpty.c already has every piece, along with the controlling-terminal and job-control rules, so a bridge reuses them unchanged. The spike showed that vi, top, `read -s`, ^C, and `SIGWINCH` all work through a pair.
- **In the kernel, not a user-space bridge.** The spike shows what a bridge outside the kernel can't do. It can't wait for a slave reader, because `poll` counts 9P files as always ready, so it steals keys. It can't stop the terminal's resize note from reaching the program as `SIGINT`. And it has to be run by hand before each program. As a kernel process, the bridge can block on devpty instead of on `cons`, and the note path can consume resize notes.
- **Connecting on the first terminal call rather than at exec.** Connecting at exec would put the window in raw mode for every Linux program whose stdio is a window, including `grep` reading a line you type, and it would take away the terminal's own line editing for no reason. Connecting on the first terminal call costs nothing for programs that never call one.
- **Replacing the fds rather than proxying the console.** A proxy would have to make every console read and write through the personality honour the pair's termios, while `poll`, `epoll`, `FIONREAD`, and `/proc/self/fd` still saw the console. Dup'ing the slave over the fds puts the process on an ordinary `#τ` fd, so the existing paths apply.
- **vt's protocol rather than a new one.** vt, Run Command, and 9front's ssh already agree on `TERM`, `LINES`, `COLS`, `WINCH`, and `winchon`. Using them needs no change to any terminal, and a new 9front terminal gets Linux programs right by following the same protocol.
- **Counting resize notes rather than comparing WINCH.** "`WINCH` changed means resize, unchanged means interrupt" breaks when two notes arrive before the first is handled. The spike saw exactly that. Counting consumed notes against `WINCH` is exact for any terminal that posts one note per increment.
- **Not blocking on `wctl`.** rio allows only one `wctl` reader, and a bridge that held it would make other programs' opens fail with `Einuse`. Plain rio windows get `TERM=dumb`, which rules out the full-screen programs that care about live resizes, so reading the size when the bridge connects is enough there.
- **The host's ptys.** These were rejected in linux-pty for the same reasons: they leave the sandbox's view, and they don't exist on Windows or the browser host.

## Compatibility

- **CLI and `Machine.Options`:** no changes.
- **h9's own console:** unchanged. The bridge applies only to window consoles.
- **Linux programs on a window console:** `isatty`, `tcgetattr`, and `TIOCGWINSZ` now succeed where they returned `ENOTTY`, and `ttyname` gives `/dev/pts/N`. A program that checks `isatty` before colouring sees a terminal, but it also sees `TERM=dumb` unless the window sets `TERM`, so output to plain rio windows stays plain.
- **Notes:** `interrupt` stops reaching a bridged Linux process as `SIGINT` when it stands for a resize. Every other note maps as it does today.
- **rio, vt, and 9/UX:** no changes. While a bridge holds the window raw, the terminal's own line editing and mouse selection of the input line are replaced by the Linux line discipline. That's what you'd expect while a Linux program runs, and it ends when the program does.
- **`third_party/`:** no changes.

## Security

The bridge reaches nothing the program couldn't already reach. It opens `cons`, `consctl`, `wctl`, and `/env` entries in the program's own namespace, beside a `cons` the program already holds, plus a `#τ` pair, which is machine-local. The pty cap from linux-pty covers the bridges. No host resources are involved, and the terminals see only what they'd see from a 9front program that set raw mode.

## Done criteria

Integration cases on the headless screen, tagged `[linux-window-tty]`, with the 9front root and the Alpine root. Each case runs rio with a vt window, or a plain window where it says so, and types through `/dev/kbdin`.

- [ ] `test "isatty is true on a vt window's cons, and tty prints /dev/pts/0 [linux-window-tty]"`
- [ ] `test "cat and grep in a pipeline leave the window cooked [linux-window-tty]"`
- [ ] `test "a Linux program in raw mode reads Esc and arrow keys as bytes [linux-window-tty]"`
- [ ] `test "read -s in ash reads a line without echoing it [linux-window-tty]"`
- [ ] `test "Ctrl-C in raw mode sends SIGINT to the foreground group [linux-window-tty]"`
- [ ] `test "stty size follows vt's LINES and COLS, and a resize sends SIGWINCH and not SIGINT [linux-window-tty]"`
- [ ] `test "a resize seen by two threads of one process is consumed once [linux-window-tty]"`
- [ ] `test "an interrupt that isn't a resize still sends SIGINT [linux-window-tty]"`
- [ ] `test "the window is back in cooked mode for rc after the program exits [linux-window-tty]"`
- [ ] `test "keys typed after the program exits reach rc whole [linux-window-tty]"`
- [ ] `test "a background Linux job doesn't take rc's input [linux-window-tty]"`
- [ ] `test "a plain rio window gets TERM=dumb and its size from wctl [linux-window-tty]"`
- [ ] `test "deleting the window sends SIGHUP to the foreground group [linux-window-tty]"`
- [ ] Demo: in a 9/UX session, busybox vi in Run Command edits and saves a file, and htop draws, follows a resize of the window, and quits on `q`.

## Implementation

1. devpty.c: `h9_pty_wantinput`, which blocks until a slave read starts or the pair closes, and the pair's resize-note count.
2. src/machine.zig: the bridge's three kernel processes, started by the pty server, with the flush on close.
3. src/abi/linux/sys.zig: window console detection and identity, connecting on the first terminal ioctl, the fd swap, the controlling terminal, and `TERM=dumb` at exec.
4. src/machine.zig and src/abi/linux/signal.zig: consuming resize notes per process before `interrupt` becomes `SIGINT`.
5. The headless cases. Then the "Roots, environment, and console" section of spec/abi-linux.md, and MANUAL.md's "Linux programs" chapter on terminals.

## Open issues

- **`interrupt` killing a handled Linux program.** In the spike, a background Linux program with a `SIGINT` handler died on an `interrupt` written to its `notepg`, instead of running the handler. If that's a bug in the note-to-signal path, it needs fixing before the bridge's note handling relies on that path, probably under linux-threads.
- **9front programs that open `/dev/cons` by name under a bridge.** When a bridged process execs a 9front program, h9 could bind the slave over `/dev/cons` in that program's namespace. That needs `consctl` semantics on a pty, either served by devpty or mapped onto termios.
- **rio's margins.** Working out the character size from `wctl` and `$font` can be off by a column if rio's border width changes. Asking terminals to publish `LINES` and `COLS` avoids the guess.
- **Two machines on one window.** A window served over 9P to a second machine would get a bridge in each machine. Only one can hold raw mode sensibly, and the second could fall back to `ENOTTY`.
- **A guest tool for older h9 builds.** The spike's `wtty` is a usable stopgap where losing a few keys after each program is acceptable. It doesn't need to ship once the bridge exists.
