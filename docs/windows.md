# Running Windows programs with h9

> A walkthrough for running Windows console programs in an h9 machine,
> with Wine in a Linux root. Programs with windows need `winedraw`, a
> display driver for Wine that's experimental and lives on the
> [`wine-draw` branch](https://github.com/progrium/hyper9/tree/wine-draw)
> ([wine-draw](../design/wine-draw.md)). It assumes you've read [chapter 20 of the manual](../MANUAL.md#20-linux-programs) on Linux
> programs. `host$` is your host shell.

h9 doesn't run Windows programs itself. It runs Linux programs, Wine is a
Linux program that runs Windows programs, and so a Windows program runs in
h9 as Wine's guest. There's no Linux kernel underneath: Wine's system
calls go to h9's Plan 9 kernel like any Linux program's.

> **Warning.** This is new and lightly tested. Wine has run `cmd`
> and small console programs in h9, not real applications. h9's
> sandbox hasn't been audited, and the native backend isn't a security
> boundary ([manual, chapter 23](../MANUAL.md#23-sandboxing)). Run Windows
> programs you'd trust on the host.

## Contents

1. [What you need](#1-what-you-need)
2. [A Wine root](#2-a-wine-root)
3. [A prefix in your directory](#3-a-prefix-in-your-directory)
4. [Console programs](#4-console-programs)
5. [Known problems](#5-known-problems)

## 1. What you need

- **An x86\_64 Linux host.** Wine runs x86\_64 Windows programs. It runs as
  an amd64 Linux program, so it needs KVM or the native backend. On a host
  without KVM, pass `--backend native`, as every example below does. Leave
  it off where `/dev/kvm` works. macOS and Windows hosts aren't covered yet.
- **64-bit programs.** Wine's WoW64 isn't set up, so a 32-bit `.exe`
  exits with status 1 and no output.

## 2. A Wine root

Wine needs a Linux root to run in. `scripts/wine-root.sh` makes one: an
Alpine 3.24 amd64 tree with Alpine's Wine 11 package in it, about 600 MB,
at `.local/linux/wine-amd64`. The package is checked against Alpine's
signing keys.

```sh
host$ scripts/wine-root.sh
linux/wine-amd64: x86_64-unix x86_64-windows
host$ export WINEROOT=$PWD/.local/linux/wine-amd64
```

Any amd64 Linux root with Wine 11 in it works the same way. Writes to the
root go to an overlay and are thrown away at exit, so put what should last
in the root on the host side, or in the prefix (next section).

## 3. A prefix in your directory

Wine keeps its Windows installation, the `C:` drive and the registry, in a
*prefix*. Put it in your working directory, which h9 shares read-write at
`/mnt/term/cwd`, so it lasts from one run to the next. Making it takes
about half a minute:

```sh
host$ mkdir ~/win && cd ~/win
host$ h9 --backend native --root "$WINEROOT" --env WINEPREFIX=/mnt/term/cwd/prefix \
        sh -c 'wineboot -i; wineserver -w'
host$ ln -s ../.. prefix/dosdevices/d:
```

**The `ln` matters.** It gives Wine a drive, `D:`, that is your working
directory. Wine's own `Z:` drive is a symlink to `/`, and h9 resolves an
absolute symlink inside the tree that holds it, so in a prefix under
`/mnt/term` it names `/mnt/term` rather than the root. Without `D:`, Windows
programs can't see your files, `cmd` starts in `C:\windows`, and
`wine /mnt/term/cwd/prog.exe` crashes. With it, Wine starts in `D:\`, and
both relative and absolute paths work. The link has to be relative.

**End each run with `wineserver -w`.** Wine saves the registry when
wineserver exits, a few seconds after the last Windows program does. h9
ends the machine as soon as its first process exits, which kills
wineserver before it saves, so registry changes (yours, or a program's
settings) are lost unless the run waits for it. A small shell function
does that, and sets the prefix:

```sh
host$ win() {
        h9 --backend native --root "$WINEROOT" \
          --env WINEPREFIX=/mnt/term/cwd/prefix --env WINEDEBUG=-all \
          sh -c 'wine "$@"; s=$?; wineserver -w; exit $s' sh "$@"
      }
```

The wait adds about ten seconds. When a run changes nothing in the
registry, `h9 ... wine prog.exe` without the function starts in about two.
`WINEDEBUG=-all` turns off Wine's own diagnostics; leave it out, or set
`WINEDEBUG=err`, when something doesn't work.

## 4. Console programs

A console program runs as soon as the prefix exists. Its output is your
terminal and its exit status is h9's:

```sh
host$ cat hello.c
#include <stdio.h>
int main(int argc, char **argv) { printf("hello from windows, %d args\n", argc); return 3; }
host$ zig cc -target x86_64-windows-gnu -o hello.exe hello.c
host$ win hello.exe "two words" x
hello from windows, 3 args
host$ echo $?
3
```

Wine's own programs run by name, and see your directory as `D:\`:

```sh
host$ echo hi > note.txt
host$ win cmd /c 'cd & type note.txt & echo made > out.txt'
D:\
hi
host$ cat out.txt
made
```

Lines a Windows program writes end in `\r\n`, as they would on Windows.
Windows programs see host files only under `D:`, your working directory,
until the `Z:` problem is fixed. Share more with `--readable` or
`--writable` on a path inside it.

## 5. Known problems

- **Absolute symlinks in the prefix.** Wine's `Z:` drive and any absolute
  symlink a program makes in the prefix point into the tree the link is in,
  not the root (section 3). The relative `D:` link is the workaround. The
  real fix is a change to how h9 resolves symlinks, which needs a
  proposal of its own ([wine-draw, open issues](../design/wine-draw.md#open-issues)).
- **`wineserver -w` is needed to keep registry changes** (section 3).
- **`sock_init: ERROR in sock_check_pollhup()`** is printed by wineserver at
  start, even with `WINEDEBUG=-all`. wineserver is checking that `poll`
  reports `POLLHUP` on a socket whose other end is shut down, and h9's
  `poll` doesn't yet. Nothing in these examples depends on it.
- **`error: XDG_RUNTIME_DIR is invalid`** comes from Wine's Wayland driver
  trying to start. It's harmless for console programs.
- **Programs with windows fail** with "no driver could be loaded": there's
  no X or Wayland server in the root. The `winedraw` driver on the
  `wine-draw` branch is the experimental answer.
- **The first run is slow.** `wineboot -i` and the first start of a
  program load and map many DLLs; later starts take a couple of seconds.
