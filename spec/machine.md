# The machine: boot, slim roots, the terminal, and graphics

This describes, as built, how a machine's namespace is put together at boot, the slim roots built from 9box, the terminal, and `--gfx`. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Slim roots](#slim-roots)
- [Boot sequence](#boot-sequence)
- [Terminal](#terminal)
- [Graphics (`--gfx`)](#graphics---gfx)
  - [On the browser host](#on-the-browser-host)

## Slim roots

`zig build slim` ([multicall](../design/epoch-0/multicall.md)) builds 9box, 9front's own commands as one statically linked multi-call binary, and a root tree around it in `.local/9front/slim-<release>-<arch>`; nothing in h9 itself changes.

`tools/slim.zig` copies `src/9box/` into a fresh build directory and runs its mkfile inside the just-built h9, against the stock root, with the build directory as the only writable path and `/sys/src` from the root or the fetched checkout bound read-only.

For each command in `src/9box/slim` (a name and a directory under `/sys/src/cmd` per line), `mkcmd` builds it as 9front does, with `mk`, behind `bind -bc` layers so `/sys/src` isn't written, reads the objects off the link line from `mk -n -a`, lists the globals they define with `nm`, and compiles them again with a `-Dname=bx_CMD_name` flag for each one libc and libbio don't define.

A command's override of a libc function (ed's `mktemp`) is renamed too, unless libc's or libbio's own code calls it; that, initialising a library global other than `argv0`, or being a thread program, fails the build.

`9box.c` picks the command from the last element of `argv[0]` (hard links), from `argv[2]` when `argv[1]` is `-!` and `argv[2]` is a `#!/bin/9box -!` file (stubs, so nested interpreters keep the outer script's name), from the interpreter a `#!` script names when `argv[0]` isn't a command (a script such as `/rc/bin/lc` whose `#!/bin/rc` is a hard link to `9box` starts it with the script's name in `argv[0]`), or from its first argument when run as `9box`, and sets `argv0` to nil before running it.

The tree is `9box`, a hard link or stub per command, `rcmain`, `/rc/bin/lc`, the time zone, and the mount points h9 binds onto. Its 44 commands are a 789 KB amd64 `9box` against 3.5 MB for the same binaries copied, as measured with 43, before `walk` joined ([mount-index](../design/epoch-0/mount-index.md)).

Each exec allocates and copies the box's text and data, so on the emulator rc's exec loop runs 9% slower from the box than from separate binaries; an exec image cache would remove most of that (the proposal's Updates have the measurements).

## Boot sequence

1. The kernel boots once per host process, on its own thread (see Process model).

2. For each machine, the namespace builder gives the first Proc a fresh Pgrp. It binds the kernel's `#/` at `/`, then adds each mount on `/` to the root stack, `#Oroot`, in order: a host tree from `#U`, a 9P server it connects to (the first one also posted as `#s/root`), an unpacked archive, the built-in root `#Hroot`, or an empty `#O` (also what a machine with nothing on `/` gets). It unions the stack after `#/` at `/`, binds it alone at `/root`, and does the same for mounts on `#L` with `#Olinux` ([mounts](../design/epoch-0/mounts.md)).

   Under `--write=overlay` (the default) and `--write=ephemeral` a `#O` overlay goes over the root stack next, before every other bind, so everything else is bound onto directories reached through it; a directory the overlay hasn't copied keeps its lower qid, so the mount table matches it.

   Then it binds the cwd and other allowed host paths from `#U` (or `#O` overlays over them under `--write=ephemeral`), a `#O` overlay over the root tree's `/tmp` (the guest's `/tmp` for a 9P or the built-in root), and `#c`, `#p`, `#d`, `#e`, `#s` (the machine's own `/srv`, with `-c`) and (unless the network is off) `#I` to their usual places, with `#ℏ` bound after it at `/net`, giving `/net/ws`, and `#H/bin` after the root's `/bin`, so h9's own commands are on the path and a root command of the same name wins.

   Mounts on other paths follow, made in the root's overlay when missing, then `--bind` lines, in order, then `--ns` lines. With guest tools, `#H/over` (h9's `bind`, which adds `-r`) is bound before `/bin`.

   A namespace file's `mount` of a URL connects during the replay, which runs before the device mask.

   It binds the machine's console over `/dev/cons` and opens fds 0–2 on it; with `--gfx` it then binds `#i`, `#m`, and `#b` after it on `/dev`.

   Under the root's overlay it makes `/usr/$user` in the overlay if the root lacks it, so `$home` exists.

   Then it sets the device mask: `#C` always (it isn't built; see [host-cmd](../design/host-cmd.md)), `#U` unless `--host-fs`, `#I` and `#ℏ` when the network is off, `#H` under `--no-guest-tools`, which also leaves out its bind, and `#b`, `#i`, and `#m` without `--gfx`. `#ι` is masked too, but only after `--ns`'s file is replayed, since its 9P mounts go through it. Existing binds keep working, but the guest can't attach a masked device again to reach more of the host.

3. If the binary is given as a host path, it's loaded straight from the host. Otherwise it's looked up through the kernel along `$path`, so lookup works the same over 9P roots.

4. The CLI runs the binary directly with the given argv. `--rc` runs `/bin/rc -c` on the argument instead.

The host's working directory is bound at the guest's `/mnt/term/cwd` and set as the guest's cwd, so that `h9 ls` lists what the user expects.

## Terminal

By default, `/dev/cons` is the machine's console device, which maps to the `Stdio` in `Machine.Options`: the host stdin and stdout for the CLI.

A read returns after one host read, as on a terminal, so a typed line reaches the guest when Enter is pressed.

That host read happens on a reader thread for the machine run (`src/consin.zig`), never on the guest's thread: the guest sleeps in the kernel (`src/kern/devhcons.c`) until the thread has input, so a note or a teardown interrupts a console read as it does any other blocking call. Nothing is read ahead of a guest's request.

At the end of a run the thread is stopped through `Stdio.in_cancel` (the CLI's stdin polls with a wake pipe on POSIX and uses `CancelSynchronousIo` on Windows).

Writing `rawon` to `/dev/consctl` switches the host TTY to raw mode (console mode on Windows). Ctrl-C posts an `interrupt` note to the foreground note group (see the CLI section's Signals and TTY for each host).

Exit status: an empty `exits` string gives 0, a decimal number from 1 to 255 gives that number, and any other string gives 1 and is printed to stderr; a process killed by a note exits 128+N for a signal (see the CLI's exit codes).

## Graphics (`--gfx`)

A machine with `Machine.Options.gfx` claims the process's one screen (`src/gfx.zig`; a second machine gets `GfxInUse`). `Options.gfx.screen` picks a host window (`.window`, `--gfx`) or the headless screen (`.headless`, `--gfx=headless`, [headless-screen](../design/headless-screen.md)). The screen opens once per process and stays, so a later machine that asks for the other kind, or the headless screen at another size, also gets `GfxInUse`.

The window is drawn by drawterm's own GUI backend, chosen at build time with `-Dgfx`: Cocoa on macOS and Win32 on Windows by default, and X11 on Linux only with `-Dgfx=x11` (glibc). The headless screen, `src/kern/gfx-headless.c`, is a screen in memory (`XRGB32`, 1024×768 unless `Options.gfx.size` says), whose flushes go nowhere and whose "host clipboard" is a buffer in the h9 process; it never opens a window or touches the host's display. It's linked into every native build with graphics, beside the window backend: `-Dgfx=headless`, Linux's default, is a build whose only screen it is. `-Dgfx=none` builds `src/kern/nogfx.c`'s stubs instead. `h9.gfx.headless`'s hooks inject keys and mouse events, read and set its clipboard, read its pixels, and close it, in any build with it; `tests/backends.zig` uses them.

The backend files are compiled unchanged; `src/kern/gfx-gui.h`, force-included before them, renames drawterm's screen interface (`screeninit`, `attachscreen`, `flushmemscreen`, `screensize`, `getcolor`, `setcolor`, `setcursor`, `mouseset`, `clipread`, and `clipwrite`) to `h9_gui_*`, and `kbdkey` to `h9_kbdkey`. `gfx-headless.c` defines the same interface as `h9_hl_*`, and `src/kern/gfx.c` defines drawterm's names, calling one set or the other by the screen the machine claimed (`h9_gfx_headless`). The backend defines `gscreen`, which the headless screen uses when it's the one open. `gfx-gui.h` also turns the backend's `exit` (X11) or `ExitProcess` (Win32) on a closed window into `h9_gfx_exit`, which posts `hangup` to the machine with the window (as for a closed terminal) and parks the backend's thread.

AppKit exits by itself, so on macOS `src/kern/gfx-cocoa.m` observes the app's termination instead, and `src/gfx.zig` posts the same `hangup` and exits with the run's status once it ends.

The window opens lazily, on the first walk below `#i` or open of `/dev/snarf`, so a program that never draws gets no window; the backend's kprocs run in an empty namespace of their own.

`/dev/kbd` serves kbdfs's format (`k`/`K` for keys held, `c` for a key typed), which rio reads, and drops keys while it isn't open. `/dev/snarf` is the host clipboard, or under `--gfx=noclip` a buffer in the h9 process; machines without `#i` can't open it.

With either screen, `gfx.c`'s wrappers around devdraw's, devmouse's, and devkbd's devtabs add three of 9front's files:

- `/dev/screen`, in `#i`'s top directory beside `draw` and `winname`: each open copies `gscreen` under `drawlock`, as an uncompressed image(6) file (a 60-byte header, then the rows), and reads come from that copy. Opening it opens the screen.
- `/dev/mousein`, in `#m`: each write is one event in `/dev/mouse`'s format, as 9front's devmouse takes it, `A` for the pointer at x, y (`absmousetrack`), `a` for x and y scaled from 0 to 2³¹ across the screen, and any other letter for a move by x, y (`mousetrack`); a msec of 0 is now. It opens the screen, since the pointer stays put without one.
- `/dev/kbdin`, in `#b`, as kbdfs's `kbdin` reads it: a write that doesn't end in a NUL is text, each rune pressed and released through `h9_kbdkey`; one that does is NUL-terminated messages, `r` and `R` a rune pressed and released, and any other (`c`, `k`, `K`) passed to `/dev/kbd`'s reader as it is.

They reach only the kernel's screen image and input queues, never the host's pointer or other host windows.

The console stays the host terminal, so `/dev/cons` and kernel prints still go there.

On macOS AppKit needs the main thread, so the CLI runs through `h9.gfx.main`, which gives AppKit the main thread and runs the machine on another; an embedder using `--gfx` on macOS does the same. The headless screen needs no AppKit, so `--gfx=headless` runs the machine directly.

### On the browser host

Web builds have `web`, h9's own backend, `src/kern/gfx-web.c` ([browser-gfx](../design/epoch-0/browser-gfx.md)), compiled with `gfx.c`, without `gfx-gui.h` and without the headless screen. Its JS half is `GfxHost` in `h9-web.js`, in the machine's Worker, which owns the page's canvas as an `OffscreenCanvas`; without one (`h9-node`, or a page that passed no `gfx`), `gfx_present` is 0 and `--gfx` fails with `GfxNotBuilt`.

- **The screen** is `gscreen` in wasm memory as `XBGR32`, at the size the page reports. `flushmemscreen` only adds a rectangle to the host's dirty rectangle; once a frame (`requestAnimationFrame` in the Worker), outside any coroutine, the host copies that rectangle's rows from wasm memory into an `ImageData`, sets each pixel's X byte to 255, and `putImageData`s it. `screensize` tells the host the new image's address, stride, and size, and the host resizes the canvas's buffer to match.
- **Input** is a queue in the host, four ints per event: a key (rune, down), the pointer (x, y, Plan 9 buttons), a resize, or a paste's length. `gfxinput`, a kernel process started by `screeninit`, takes them through the Suspending `gfx_wait` (saving what's per thread around it, as every Suspending import does) and calls `h9_kbdkey`, `absmousetrack`, and `screenresize`, so the input paths run with `up` set.
- **The page** (`createMachine`) maps pointer events (with capture while a button is down, the wheel as buttons 8 and 16, and Alt- and Cmd- or Ctrl-click as buttons 2 and 3) and keys (`KeyboardEvent.key` to `keyboard.h`'s runes, sent only while the canvas has focus, a release sending its press's rune, and every held key released on blur) to the Worker, and posts the screen's size from a `ResizeObserver`: device pixels for scale 0, CSS pixels for 1, and device pixels divided by N otherwise.
- **The clipboard.** In `page` mode `/dev/snarf` is a buffer in `gfx-web.c`. A `paste` event on the focused canvas replaces it, and a write to it is posted to the page, which calls `navigator.clipboard.writeText` and fires `snarf` on the machine if that's refused. `private` is `--gfx=noclip`, `gfx.c`'s own buffer.
- **The cursor**: `setcursor` posts `/dev/cursor`'s 72 bytes, or nothing for the arrow, and the page draws them into a PNG for the canvas's CSS `cursor`. `mouseset` does nothing, since a page can't move the pointer.
- `machine.hangup()` posts `hangup` through the Worker's signals, as a closed window does. The plan's `gfx:` line says `clipboard=page`, with caveats for the page's clipboard and the canvas.
