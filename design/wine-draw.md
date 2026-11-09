---
slug: wine-draw
title: Wine windows through draw
status: draft
created: 2026-11-09
authors: [progrium]
depends: [15, 18]
areas: [linux, kern, build, tests]
---

# Proposal: Wine windows through draw

## Abstract

Windows programs under Wine get a window. `winedraw.drv` is a Wine display driver whose Unix side draws through `/dev/draw` and reads `/dev/mouse` and `/dev/kbd`, so a Wine program runs in the `--gfx` window (or a rio window) with no X or Wayland server in the Linux root. A Linux process reaches those files through `/dev/9`, a new directory in the Linux view that is the process's own 9front `/dev`. Each Windows top-level window is a draw window (a layer) on one public screen that every Wine process in the machine shares, so devdraw stacks and clips windows across processes, as it does rio's. The driver uses only the draw files, so it should work unchanged wherever [gfx](0015-gfx.md) does, including [browser-gfx](0120-browser-gfx.md) once the Linux personality runs there.

## Background

64-bit Wine 11 starts on the [Linux personality](0018-linux-personality.md) and runs console programs (`wine cmd /c ver`). A program that opens a window fails: Wine finds no display driver ("nodrv"), since the root has no X or Wayland server to connect to, and h9 has nowhere to put one.

Wine splits drawing from presenting. `win32u` (the Unix side of `user32` and `gdi32`) renders GDI into window surfaces itself, in its DIB engine, and calls a *user driver* only to present those surfaces, manage native windows, and turn native input into Windows messages. The interface is `struct user_driver_funcs` in `include/wine/gdi_driver.h` (version 108 in Wine 11.0). A driver fills in the functions it needs and registers them from its Unix library's init with `__wine_set_user_driver`; the rest fall back to `win32u`'s null driver. Wine's `explorer` picks the driver by name from `HKCU\Software\Wine\Drivers`, `Graphics` (by default it tries the Mac, X11, and Wayland drivers in turn), and loads `wine<name>.drv`, a small PE DLL, which loads its Unix library `wine<name>.so`.

Wine 11 ships three drivers: `winex11.drv` (about 30 functions filled in), `winewayland.drv` (21, including `CreateWindowSurface`, `WindowPosChanged`, `SetCursor`, `UpdateDisplayDevices`, and a desktop window proc), and `winemac.drv`. In each, the work that's specific to the window system is small next to Wine: put a surface's dirty pixels on screen, map keys and buttons, set the cursor, and report the display's size.

On the h9 side, gfx serves `/dev/draw`, `/dev/mouse`, `/dev/cursor`, `/dev/kbd`, `/dev/winname`, and `/dev/snarf` in a machine's 9front namespace, from the host window or the headless test screen. A Linux process shares its Proc's namespace, but its `/` is `#λ`, whose `/dev` serves only Linux's files, so a Linux program can't open the draw files today.

## Proposal

**`/dev/9` in the Linux view.** devlinux's `/dev` gains `9`, a mount point, and the namespace builder binds the machine's 9front `/dev` on it, so `open("/dev/9/draw/new")` in a Linux process opens the host window's `#i` under `--gfx`. The bind copies `/dev`'s union as the machine starts, so binds made on `/dev` later, such as rio's for a window, aren't in it; a Linux process started from a rio window finds those under `/9/dev`, the 9front root's `/dev`, when the machine has a 9front root. Without `--gfx` the gfx devices are masked as now, so `/dev/9/draw` doesn't exist. Reads, writes, and `stat` pass straight through; `/dev/9` adds no device of its own.

**`winedraw.drv`.** A display driver in `src/wine/`, in C, in two parts:

- `winedraw.drv`, the PE side: a `DllMain` that finds the Unix library as winecrt0's `__wine_init_unix_call` does, calls its init, and starts the input threads. It's built with `zig cc -target x86_64-windows-gnu` and no C runtime, so it imports only `kernel32` and no MinGW is needed. `tools/winebuiltin.zig` writes the "Wine builtin DLL" marker into its DOS stub, as `winebuild` does: Wine gives only a builtin DLL a Unix library.
- `winedraw.so`, the Unix side, built with `zig cc` against Wine's headers for the targeted release (`include/` from the pinned Wine source, fetched by `scripts/fetch.sh wine`, not vendored). An empty `win32u.so` stub makes the link list Wine's `win32u.so` as needed, so the build needs no Wine binaries.

The Unix side fills in these functions in the first version:

| Function | What it does |
|---|---|
| `UpdateDisplayDevices` | Reports one monitor and mode, the size of the window named by `/dev/9/winname` |
| `CreateWindowSurface` | Gives each top-level window a surface with an `x8r8g8b8` staging image of its size in draw |
| `WindowPosChanged` | Allocates the window's layer at its visible rectangle, or frees it when hidden or moved, and raises it when it comes to the top |
| `ActivateWindow` | Raises the window's layer |
| `DestroyWindow` | Frees the layer |

A flush loads the dirty rectangle into the staging image with draw's `y` (load) message, draws it onto the window's layer with `d`, and writes `v` to flush. Wine's surfaces are 32-bit BGRX, which is draw's `x8r8g8b8` byte for byte; drawing from the staging image converts to the screen's format, whatever it is. A new or moved layer gets the whole surface on the next flush.

Input comes from two threads that the PE side starts in each process, which run in the Unix library: one reads `/dev/9/mouse` and one `/dev/9/kbd`. Each file allows one reader, so the first Wine process (usually `explorer`, the desktop) reads them for all, and the others' threads end. They turn input into `NtUserSendHardwareInput`, and wineserver routes it to the right window in whatever process. Mouse messages give the position and buttons, with the wheel's buttons 4 and 5; kbd's `k` and `K` messages list the keys held after a press and after a release, so the difference from the last message is a key down or up, sent as a US layout's scan code, which `win32u`'s default keyboard tables translate. A process that doesn't create windows never opens draw: the connection opens with the first window surface.

**Windows as draw windows on a shared screen.** Each top-level window is a layer (`b` with a screen id, refreshed from its own backing store) on a public screen with a fixed id. The first process to draw makes the screen over the machine's window (`A`), filled with Windows' default desktop color, and every other process uses it (`S`), so devdraw stacks, clips, and uncovers windows across processes, and Wine draws its own title bars inside each. The screen stays one window as far as rio or the host is concerned.

**Selecting it.** `h9` doesn't set it automatically. `zig build wine` builds the two files into `zig-out/wine/x86_64-windows` and `x86_64-unix`, the layout of Wine's own `lib/wine`, and they're copied into a Linux root's `/usr/lib/wine`; in a Wine prefix, `Graphics=draw` under `HKCU\Software\Wine\Drivers` picks the driver. With no window (no `--gfx`) its init fails and Wine falls back as it does without a display. A Wine whose `WINE_GDI_DRIVER_VERSION` doesn't match the one the driver was built for refuses it at registration, and Wine says why.

**Not in the first version:** the cursor's shape and moving the pointer (`SetCursor`, `SetCursorPos`, `ClipCursor`), following a resized window (the display keeps its first size), OpenGL and Vulkan (`OpenGLInit` and `VulkanInit` aren't filled in, so Direct3D and anything that needs GL fails as it would with no GL driver), the clipboard (`/dev/9/snarf` is there for a later step), IME, layouts other than US, and 32-bit (WoW64) Wine.

## Rationale

**A display driver rather than an X server.** An X server whose output is a draw window would run `winex11.drv` unchanged, and every other X11 program too. A bridge is the cheapest form: Alpine's `Xvfb` drawing into memory, and a small program that copies its damaged rectangles to `/dev/draw` and feeds input back with XTEST. It's left out of this proposal, not rejected. It needs SysV shared memory or a mapped framebuffer, the X stack in the root, and two copies of every frame, and it shows X's view of Wine, whose virtual desktop is still one X window. If running Linux X11 programs in general is wanted, that bridge is the better project, and it should be a proposal of its own; this one targets Wine.

**A display driver rather than a Wayland compositor.** A minimal compositor over draw (`wl_compositor`, `wl_shm`, `xdg_shell`, `wl_seat`) would serve `winewayland.drv` and GTK and Qt programs. It's more code than the driver (the protocol, a server library, and shared memory buffers passed with `SCM_RIGHTS`, which h9 has now), and Wine's Wayland driver still lacks pieces that its X11 driver has, such as window positions.

**Draw's own protocol, not drawterm's libdraw.** The driver needs about five draw messages (allocate an image, load, draw, free, flush) and the `/dev/mouse` and `/dev/kbd` formats. Writing them directly keeps the driver free of Plan 9 libc, so it builds with Wine's headers and the Linux libc alone.

**`/dev/9` rather than a device for each file.** Exposing the process's own 9front `/dev` covers draw, rio's per-window files, `snarf`, and whatever comes later with one directory, and a Linux process sees exactly what a 9front process in its place would. The name keeps clear of Linux's own `/dev` entries.

**Draw windows on one screen, not a virtual desktop or rio windows.** A virtual desktop (one draw image that the driver composes every window into) would need the driver to know every window's stacking order and contents, across processes, since each Wine process has its own connection; devdraw's screens already do that, so a layer per window is less code. Mapping each Windows top-level window to a rio window (through `/dev/wsys`) needs window management in both directions: moves, z-order, focus, and minimizing. That's most of `winex11.drv`'s size, and one screen is enough to run real programs and to tell whether the rest is worth doing.

## Compatibility

No CLI flags, exit codes, `Machine.Options`, or sandbox defaults change. The Linux view gains `/dev/9`. `third_party/` is unchanged: the driver builds against Wine's headers fetched by `scripts/fetch.sh`, and `zig build wine` is a new, optional step. The driver is tied to one Wine release's driver interface (Wine 11.0 to start), so a Wine upgrade in a root needs the driver rebuilt, and possibly changed, for that release.

## Security

`/dev/9` gives a Linux process the files its 9front namespace already has, and nothing else: a 9front program in the same Proc could open the same files today. The gfx devices are masked without `--gfx`, so a Linux process can't open a window unless the machine was given one. The policy is unchanged.

## Done when

Demo: `h9 --gfx --root <alpine root with wine and the driver> wine notepad`, in a prefix with `Graphics=draw`, opens Notepad in the window, and typing and clicking work.

Cases tagged `[wine-draw]`:

- Integration: "/dev/9 in the Linux view is the machine's 9front /dev, with no draw files without --gfx", and "with --gfx, a Linux program opens the window's draw files through /dev/9", which needs an h9 built with `-Dgfx=headless`.
- Backend (`tests/backends.zig`, on the headless screen, whose test hooks inject input): "a Wine program draws on the window through winedraw, and gets clicks and keys". `wdtest.exe`, a Win32 program built with `zig cc -target x86_64-windows-gnu`, fills its client area with red; the test reads red from the screen, clicks until it turns green, and types `a` and `q`, which the program prints. It needs a root with Wine in it (`scripts/wine-root.sh`, named by `H9_TEST_WINE_ROOT`) and `zig build wine`'s files, and skips without them.

`tests/fixtures/linux/drawpeek` reads the window's pixels back through `/dev/9/draw`, to check a run by hand or save it as a PPM image.

## Implementation

1. `/dev/9` in devlinux, with its fixture case.
2. `scripts/fetch.sh wine` fetches Wine 11.0's `include/` at a pinned commit, and `zig build wine` builds `winedraw.drv` and `winedraw.so`.
3. The driver: registration, `UpdateDisplayDevices`, window surfaces, layers on the shared screen, and flushing. The color part of the backend case passes.
4. Input: the mouse and keyboard threads and the US layout. The click and key parts pass.
5. The cursor, resizes, and the Notepad demo, with notes on what larger programs need next.

## Open issues

- Fetching Wine's source to build a driver of about a thousand lines is heavy. Alpine's `wine-dev` 11.0 ships `wine/unixlib.h` but not `wine/gdi_driver.h` or the other internal headers a driver includes. Vendoring just the headers the driver includes, at a pinned release, may be better.
- Whether a Linux root's Wine is the only target, or h9 should provide a Wine build with the driver in it, so the version always matches.
- Keyboard layouts beyond US, and keys that `/dev/kbd` reports as runes with no scan code.
- Whether the X server bridge in Rationale should come first, since it would cover both Wine and Linux X11 programs.
- Wine can't reach Unix paths through its `Z:` drive. `Z:` is the symlink `dosdevices/z: -> /` in the prefix, and h9 resolves an absolute symlink inside the tree that holds it ([symlinks-in-root](0034-symlinks-in-root.md)), so in a prefix under `/mnt/term` it names `/mnt/term`, and under `/tmp` it names `/tmp`. That's why Wine can't open a working directory under `/mnt/term` ("could not open working directory"), why `wine /mnt/term/cwd/prog.exe` segfaults while `wine prog.exe` runs, and likely why a `WINEDLLPATH` there isn't searched. A relative drive symlink works around it: with the prefix in the shared directory, `dosdevices/d: -> ../..` names that directory, Wine starts in `D:\`, and absolute paths under it run ([docs/windows.md](../docs/windows.md)). The fix is for h9 to resolve absolute symlinks in the Linux view rather than in the tree they're in, at least in trees the guest writes, such as `/tmp` and the overlays. It changes 0034's rule, so it needs its own proposal.
