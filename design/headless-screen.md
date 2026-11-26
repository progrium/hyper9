---
slug: headless-screen
title: Headless screen (--gfx=headless)
status: implemented
created: 2026-11-23
authors: [progrium]
depends: []
areas: [cli, kern, build, tests]
branch: [main]
---

# Proposal: Headless screen (--gfx=headless)

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

`--gfx=headless` gives a machine a screen in memory instead of a host window, in every native build, with no display and no window-system libraries. Three files that 9front already has, `/dev/screen`, `/dev/mousein`, and `/dev/kbdin`, let programs in the machine read the screen and type and click into it. GUI tests, and agents that drive rio, can then be plain rc scripts run by the `h9` binary, rather than Zig programs that embed h9 to reach the headless backend's test hooks.

## Background

[gfx](epoch-0/gfx.md) added `--gfx` and a headless backend, `src/kern/gfx-headless.c`, for its own tests. The headless backend is a build-time choice (`-Dgfx=headless`), and its hooks (inject a key or a mouse event, read the clipboard, copy the pixels, close the window) are reachable only through `h9.gfx.headless` in Zig. The test module is always built with it, so the `[gfx]` cases in `tests/backends.zig` run everywhere, but the `h9` binary can't use it.

That leaves anyone testing a 9front GUI program on h9 with two choices:

- **Embed h9 in a Zig program** built with `-Dgfx=headless`. 9ux does this: its harness in `test/harness` is a Zig program that runs rio, with an rc agent inside rio so most of a test can still be rc. It needs h9 as a path dependency and its own build ([9ux's h9-needs.md](https://github.com/progrium/9ux/blob/main/docs/h9-needs.md), "No headless screen from the command line").
- **Use a real window.** On Linux that needs a `-Dgfx=x11` build against glibc and libX11, and Xvfb in CI. On macOS and Windows it needs a logged-in desktop session.

Inside a machine, nothing can read the screen or fake input. drawterm's devdraw, devmouse, and devkbd, which h9 serves as `#i`, `#m`, and `#b`, have no `/dev/screen`, `/dev/mousein`, or `/dev/kbdin`, though 9front's kernel and kbdfs do.

## Proposal

### The flag

- `--gfx=headless` gives the machine a screen in memory, as `-Dgfx=headless` does today: `#i`, `#m`, and `#b` on `/dev`, a 1024×768 XRGB32 screen, flushes that go nowhere, and a clipboard that's a buffer in the h9 process (so `/dev/snarf` is always private, as with `--gfx=noclip`). It never opens a window and never touches the host's clipboard, display, or window system.
- `--gfx-size WxH` sets the headless screen's size, `1024x768` by default. Given without `--gfx=headless`, it's a usage error (exit 2, as h9's other usage errors are).
- `--gfx-scale` and `--gfx=noclip` don't apply to the headless screen; giving either with it, or `--gfx` with it, is a usage error.
- The rest of [gfx](epoch-0/gfx.md) holds: the screen opens lazily, one machine per process has it (`GfxInUse` for a second), and `#i`, `#m`, and `#b` stay masked without `--gfx`.
- There's no close button. The run ends when its program does, or when the host terminal closes, as without `--gfx`. `h9.gfx.headless.close()` stays for embedders that want a test to close the screen as a window's close button would.
- `--print`'s `gfx:` line says `headless WxH`, with no clipboard caveat.

### The files

Three files appear with any `--gfx`, headless or windowed, through the wrappers h9 already puts around devdraw's, devmouse's, and devkbd's devtabs in `src/kern/gfx.c`:

| File | From | Read | Write |
| --- | --- | --- | --- |
| `/dev/screen` | `#i` | The screen as an uncompressed image(6) file, as 9front's `/dev/screen` is, so `topng`, `page`, and `crop` read it. Taken under `drawlock`, so it's a consistent frame. | — |
| `/dev/mousein` | `#m` | — | Mouse events in `/dev/mouse`'s own `m x y buttons msec` format, one per write, as 9front's `/dev/mousein` takes them: `A` for the pointer at x, y, `m` for a move by x, y, and `a` for x and y scaled across the screen. They move the kernel's pointer, not the host's. |
| `/dev/kbdin` | `#b` | — | Text, typed into the screen rune by rune (each pressed, then released), as kbdfs's `kbdin` does. Ctrl and the other modifiers go in as kbdfs's `k`/`K` lines would. |

They're the 9front names and formats, so a script written for 9front runs unchanged.

A GUI test is then an ordinary run:

```
host$ h9 --gfx=headless rio -i 'window -r 0 0 800 600 test.rc'
```

where `test.rc` types and clicks through `/dev/kbdin` and `/dev/mousein`, checks `/dev/snarf` or the files a program writes, and saves `topng </dev/screen >/mnt/term/cwd/shot.png` when something fails. A host-side client that wants the same files mounts them over [serve](epoch-0/serve.md): `/dev` is bound in the plan's namespace, so `--serve` exports them.

### The build

The headless screen is linked into every native build, next to the window backend, rather than chosen by `-Dgfx`:

- `src/kern/gfx-gui.h` already renames the window backends' `screeninit`, `clipread`, `clipwrite`, `setcursor`, and `mouseset`. It also renames the rest of drawterm's screen interface (`attachscreen`, `flushmemscreen`, `screensize`, `getcolor`, `setcolor`), and `gfx-headless.c` defines its own under another prefix, so both link into one binary. `src/kern/gfx.c` calls one set or the other, by the screen the machine asked for.
- The headless screen needs nothing beyond memdraw, which `#i` links anyway, so every build has it. On Linux, where releases are static and the default is `-Dgfx=none`, the default becomes `-Dgfx=headless`: the release `h9` gains `--gfx=headless`, and `--gfx` (a window) still exits 125 as it does today. `-Dgfx=none` keeps building `nogfx.c`, for builds that want no graphics at all.
- `-Dgfx=headless` keeps its meaning: a build whose only screen is the headless one. The test module keeps using it.
- The browser host's `web` backend isn't changed. A canvas already gives the browser a screen, and `h9-node`'s `--gfx` keeps exiting 125 (see Open issues).

### The API

- `Machine.Options.gfx` gains `screen: enum { window, headless } = .window`, and `size: ?struct { dx: u16, dy: u16 } = null` for the headless screen's size. `GfxNotBuilt` is returned for `.window` in a build with only the headless screen, and for either in a `-Dgfx=none` build.
- `h9.gfx.headless`'s hooks are available in any build that has the headless screen, not only `-Dgfx=headless` builds, and act on the machine whose screen is headless.

## Rationale

**Files in the machine, not a control socket on the host.** A socket would be a new protocol to specify, version, and keep working on three host OSes, and a test would need a client for it beside the h9 run. The files are 9front's own, with formats 9front tools already speak, and the guest is where a 9front GUI test wants to be: it has rc, `topng`, `cmp`, and the programs under test. The host gets them too, over `--serve`, without a second protocol.

**For every `--gfx`, not only the headless screen.** One interface means a test written against the headless screen runs against a real window unchanged, which is how a backend's own window code can be checked by hand. What the files reach is the guest's own screen and input queue, which the guest already controls; see Security.

**Linked in, not a separate build.** A separate build is what exists today, and it's why the CLI can't use the headless screen. The renaming is mechanical, follows the pattern `gfx-gui.h` already uses for the backends' exits, and leaves the vendored tree unmodified. The cost is one more set of renamed symbols and a branch per screen call in `gfx.c`, on a path that isn't hot.

**Linux's default becomes `headless`.** It's the one screen a static Linux binary can have, it adds no libraries, and CI on Linux is where GUI tests most need it. `none` stays for anyone who wants the masked devices to have no code behind them.

**Xvfb instead.** It works today, but only with `-Dgfx=x11`, which means glibc, libX11 and libXt headers, and a display server per test. It doesn't help macOS or Windows CI, and it still gives the guest no way to read the screen.

**The Zig harness instead.** It works too, as 9ux shows, and it stays possible. But each project that tests a GUI on h9 would write its own, and needs h9 as a Zig dependency, which [h9-needs.md](https://github.com/progrium/9ux/blob/main/docs/h9-needs.md) also found is harder than it should be.

**Not in this proposal:** waiting for the screen to settle. A test that types and then reads `/dev/screen` has to poll or sleep; a `/dev/screenwait` or a damage counter could come later, in its own proposal, once tests show what they need. Recording (a frame on each flush, for a video of a failed run) is left out for the same reason.

## Compatibility

- **CLI:** `--gfx=headless` and `--gfx-size` are new. `--gfx-size` without `--gfx=headless`, or `--gfx-scale` or `--gfx=noclip` with it, is a usage error (exit 2). `--gfx=headless` in a `-Dgfx=none` build, or on the browser host, exits 125, as `--gfx` without a backend does.
- **`Machine.Options`:** `gfx.screen` and `gfx.size` are new, with defaults that keep today's behaviour.
- **Builds and releases:** Linux builds default to `-Dgfx=headless` instead of `none`, so Linux release binaries grow by the headless backend, which is small since memdraw is linked into every build already. macOS and Windows builds gain the headless screen next to their window backend.
- **`--version` and `--check`:** the `gfx:` line lists both screens, such as `gfx: cocoa, headless`.
- **Root tree:** unchanged. `topng`, `page`, and `crop` are in a full 9front root (`zig build mkroot`), though not in the slim root's command set.
- **Vendored tree:** unchanged. The renaming is done by `gfx-gui.h`, and the three files by h9's wrappers.

## Security

- **The headless screen reaches nothing on the host.** No window, no display connection, and no host clipboard: `/dev/snarf` is a buffer in the h9 process. It's still an explicit grant, since `#i`, `#m`, and `#b` stay masked without `--gfx`.
- **`/dev/mousein` and `/dev/kbdin`** let any program in the machine send input to whatever reads the screen's mouse and keyboard, usually rio. That's 9front's model too, and the guest already owns every program on its screen. With a real window, injected events go only to the guest's input queues: the host's pointer doesn't move, and no other host window gets them.
- **`/dev/screen`** reads devdraw's screen image, which holds only what the guest drew. With a real window it never includes other host windows or the desktop, since the window backends copy that image out to the window, never back in.
- **Over `--serve`,** the files are exported only when `/dev` is, as any device is, under `--serve-root` and `--write=none`.

## Done criteria

Integration cases in `tests/*.zig`, run by the `h9` binary, tagged `[headless-screen]`:

- [x] `test "--gfx=headless binds /dev/draw, /dev/mouse, /dev/kbd and /dev/screen [headless-screen]"`
- [x] `test "/dev/screen is an image(6) file of the headless screen's size [headless-screen]"`: with `--gfx-size 640x480`, the header says `x8r8g8b8 0 0 640 480`.
- [x] `test "a draw client's image shows up in /dev/screen [headless-screen]"`
- [x] `test "a line written to /dev/mousein reaches /dev/mouse [headless-screen]"`
- [x] `test "text written to /dev/kbdin reaches /dev/kbd as typed keys [headless-screen]"`
- [x] `test "--gfx=headless keeps /dev/snarf away from the host clipboard [headless-screen]"`
- [x] `test "rio starts on the headless screen, and kbdin types a command into its window [headless-screen]"`: `rio -i 'window rc'`, then `kbdin` types `echo hi > /dev/snarf`, and `/dev/snarf` reads `hi`.
- [x] `test "--gfx-size without --gfx=headless is a usage error [headless-screen]"`
- [x] `test "--gfx=headless in a -Dgfx=none build exits 125 [headless-screen]"`

Backend cases in `tests/backends.zig`, tagged `[headless-screen]`:

- [x] `test "a second machine in the process gets GfxInUse for the headless screen [headless-screen]"`
- [x] `test "with Options.gfx.screen = .headless, the hooks reach the machine's screen in a windowed build [headless-screen]"`

Demos, by hand: `h9 --gfx=headless rio -i 'window rc'` with a script that types into the window and saves `topng </dev/screen`, on Linux (the static release build), macOS, and Windows; and the same script run under `h9 --gfx rio` against a real window, unchanged.

## Implementation

1. `/dev/screen`, `/dev/mousein`, and `/dev/kbdin` in `src/kern/gfx.c`'s wrappers. Their backend cases pass on the existing `-Dgfx=headless` test module.
2. The renaming in `gfx-gui.h` and `gfx-headless.c`, and `gfx.c` choosing a screen per machine. `Machine.Options.gfx.screen` and `size`, and the hooks in any build with the headless screen.
3. `--gfx=headless` and `--gfx-size` in `src/cli.zig`, the plan's `gfx:` line, `--version`, and `--check`. Linux's default becomes `-Dgfx=headless`. The integration cases pass.
4. The rio case and the demos on each host.
5. MANUAL.md's graphics chapter and CLI table, README's build options, and the spec file that covers gfx. Set `status: implemented`.

## Open issues

- Whether `h9-node` should get the headless screen too, so web tests can run rio without Chromium. `gfx-web.c` would need the same renaming, and Node has no canvas, so it would be the only screen there.
- Whether `--gfx-size` should also set a real window's initial size. drawterm's backends pick their own, and Cocoa remembers it per app.
- A `--gfx-snap FILE` that writes the screen as PNG when the run ends would save tests the `topng` step on failure, and would help when a run hangs before its script can save anything (9ux's `start-failed.png`). It needs a PNG encoder on the host side, which h9 doesn't have.

## Updates

- 2026-11-25: Built on the `headless-screen` branch, steps 1 to 5. The integration cases pass on the native backend (amd64, the release ISO's root), the rio case included, and the backend cases on the emulator. The exit code for the flag conflicts is 2, as for h9's other usage errors, rather than the 125 this proposal first said; that case is renamed to match. `/dev/mousein` takes 9front's `A` (absolute), `a` (scaled), and other letters (relative), and `/dev/kbdin` kbdfs's text and NUL-terminated messages. The screen opens once per process, so a machine that asks for a window after another opened the headless screen (or the other way around, or the headless screen at another size) gets `GfxInUse`. The backend tests now use the `-Dgfx` build's headless screen when it has one, so `zig build test -Dgfx=x11` runs the windowed-build case. Not yet done: the demos by hand on macOS and Windows, and a build of the Cocoa and Win32 backends with the wider renaming in `gfx-gui.h`, which this branch's CI runs; the status stays `draft` until they pass.
- 2026-11-25: Implemented. CI's dispatched run built the Cocoa and Win32 backends with the headless screen linked in beside them. On macOS (Cocoa, arm64) the backend cases pass, the two `[headless-screen]` ones and the `[gfx]` rio and acme cases among them, and so do the integration runs on the emulator. On Windows the build links and the `[headless-screen]` backend cases pass. The `[gfx]` rio and acme cases fail there on the emulator, as they already did on main with the headless-only test build. That run also found a bug in the GfxInUse case: on macOS a window claim beside the headless screen is `GfxUnavailable`, and the case left the screen claimed when it failed. It now accepts that and gives the screen up. The demos haven't been run by hand on macOS or Windows; CI's rio cases are the stand-in for them.
