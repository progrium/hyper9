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

Windows programs under Wine get a window. `winedraw.drv` is a Wine display driver whose Unix side draws through `/dev/draw` and reads `/dev/mouse` and `/dev/kbd`, so a Wine program runs in the `--gfx` window (or a rio window) with no X or Wayland server in the Linux root. A Linux process reaches those files through `/dev/9`, a new directory in the Linux view that is the process's own 9front `/dev`. The first version runs Wine as a virtual desktop: one draw image holds Wine's desktop, top-level windows are drawn inside it by Wine, and the driver copies what changed onto the screen. The driver uses only the draw files, so it should work unchanged wherever [gfx](0015-gfx.md) does, including [browser-gfx](0120-browser-gfx.md) once the Linux personality runs there.

## Background

64-bit Wine 11 starts on the [Linux personality](0018-linux-personality.md) and runs console programs (`wine cmd /c ver`). A program that opens a window fails: Wine finds no display driver ("nodrv"), since the root has no X or Wayland server to connect to, and h9 has nowhere to put one.

Wine splits drawing from presenting. `win32u` (the Unix side of `user32` and `gdi32`) renders GDI into window surfaces itself, in its DIB engine, and calls a *user driver* only to present those surfaces, manage native windows, and turn native input into Windows messages. The interface is `struct user_driver_funcs` in `include/wine/gdi_driver.h` (version 108 in Wine 11.0). A driver fills in the functions it needs and registers them from its Unix library's init with `__wine_set_user_driver`; the rest fall back to `win32u`'s null driver. Wine's `explorer` picks the driver by name from `HKCU\Software\Wine\Drivers`, `Graphics` (by default it tries the Mac, X11, and Wayland drivers in turn), and loads `wine<name>.drv`, a small PE DLL, which loads its Unix library `wine<name>.so`.

Wine 11 ships three drivers: `winex11.drv` (about 30 functions filled in), `winewayland.drv` (21, including `CreateWindowSurface`, `WindowPosChanged`, `SetCursor`, `UpdateDisplayDevices`, and a desktop window proc), and `winemac.drv`. In each, the work that's specific to the window system is small next to Wine: put a surface's dirty pixels on screen, map keys and buttons, set the cursor, and report the display's size.

On the h9 side, gfx serves `/dev/draw`, `/dev/mouse`, `/dev/cursor`, `/dev/kbd`, `/dev/winname`, and `/dev/snarf` in a machine's 9front namespace, from the host window or the headless test screen. A Linux process shares its Proc's namespace, but its `/` is `#λ`, whose `/dev` serves only Linux's files, so a Linux program can't open the draw files today.

## Proposal

**`/dev/9` in the Linux view.** devlinux's `/dev` gains `9`, a directory that resolves names in the calling process's 9front namespace under `/dev`. `open("/dev/9/draw/new")` in a Linux process opens what `/dev/draw/new` is for a 9front process in the same Proc: the host window's `#i` under `--gfx`, or rio's per-window files when the process was started from a rio window. Without `--gfx` the gfx devices are masked as now, so `/dev/9/draw` doesn't exist. Reads, writes, and `stat` pass straight through; `/dev/9` adds no device of its own.

**`winedraw.drv`.** A display driver in `src/wine/`, in C, in two parts:

- `winedraw.drv`, the PE side: a `DllMain` that loads the Unix library with `__wine_init_unix_call`, and calls its init. It's built with `zig cc -target x86_64-windows-gnu`, so no MinGW is needed.
- `winedraw.so`, the Unix side, built with `zig cc` against Wine's headers for the targeted release (`include/` from the pinned Wine source, fetched by `scripts/fetch.sh`, not vendored).

The Unix side fills in these functions in the first version:

| Function | What it does |
|---|---|
| `UpdateDisplayDevices` | Reports one monitor, the size of the window's rectangle from `/dev/draw/new` (and `/dev/winname` for its image) |
| `CreateWindowSurface` | Gives each window `win32u`'s DIB-backed surface, with a `flush` that queues its dirty rectangle |
| `DesktopWindowProc` | Serves the virtual desktop |
| `WindowPosChanged` | Marks the moved region for a flush |
| `SetCursor` | Converts a Windows cursor to the 16×16 image and mask `/dev/cursor` takes (the nearest fit; color cursors are thresholded) |
| `SetCursorPos`, `ClipCursor` | Write `/dev/mouse` to move the pointer; clipping is ignored at first |
| `KbdLayerDescriptor` | A US layout, to start |

A flush loads the dirty rectangle into an image of the window's size with draw's `y` (load) message, draws it onto the screen image with `d`, and writes `v` to flush. Wine's surfaces are 32-bit BGRX, which is draw's `XRGB32` byte for byte, so there's no conversion. One thread per process reads `/dev/mouse` and `/dev/kbd` and turns them into input through `NtUserSendHardwareInput`: mouse messages give the position and buttons (with wheel buttons 4 and 5), kbd's `k` and `K` messages list the keys held after a press and after a release, so the difference from the last message is a key down or up, mapped to virtual keys and scan codes, and a resize (`r` from `/dev/mouse`) reattaches the window and calls `UpdateDisplayDevices`. A process that doesn't create windows (`wineserver`, services) never opens the draw files, so draw isn't opened until the first window surface or display query.

**Virtual desktop only, at first.** The driver always runs Wine's desktop as one window the size of the draw window (`explorer /desktop`), so Windows programs' top-level windows are drawn inside it by Wine, with its own title bars, and positioning and focus never reach rio. This is the mode `winex11.drv` uses with a virtual desktop, and it keeps the driver to presenting one surface.

**Selecting it.** `h9` doesn't set it automatically. In a Wine prefix, `Graphics=draw` under `HKCU\Software\Wine\Drivers` picks it, and `zig build wine` installs the two files into a Linux root's `/usr/lib/wine/x86_64-windows` and `x86_64-unix`. A Wine whose `WINE_GDI_DRIVER_VERSION` doesn't match the one the driver was built for refuses it at registration, and Wine says why.

**Not in the first version:** OpenGL and Vulkan (`OpenGLInit` and `VulkanInit` aren't filled in, so Direct3D and anything that needs GL fails as it would with no GL driver), the clipboard (`/dev/9/snarf` is there for a later step), IME, a window per top-level window, and 32-bit (WoW64) Wine.

## Rationale

**A display driver rather than an X server.** An X server whose output is a draw window would run `winex11.drv` unchanged, and every other X11 program too. A bridge is the cheapest form: Alpine's `Xvfb` drawing into memory, and a small program that copies its damaged rectangles to `/dev/draw` and feeds input back with XTEST. It's left out of this proposal, not rejected. It needs SysV shared memory or a mapped framebuffer, the X stack in the root, and two copies of every frame, and it shows X's view of Wine, whose virtual desktop is still one X window. If running Linux X11 programs in general is wanted, that bridge is the better project, and it should be a proposal of its own; this one targets Wine.

**A display driver rather than a Wayland compositor.** A minimal compositor over draw (`wl_compositor`, `wl_shm`, `xdg_shell`, `wl_seat`) would serve `winewayland.drv` and GTK and Qt programs. It's more code than the driver (the protocol, a server library, and shared memory buffers passed with `SCM_RIGHTS`, which h9 has now), and Wine's Wayland driver still lacks pieces that its X11 driver has, such as window positions.

**Draw's own protocol, not drawterm's libdraw.** The driver needs about five draw messages (allocate an image, load, draw, free, flush) and the `/dev/mouse` and `/dev/kbd` formats. Writing them directly keeps the driver free of Plan 9 libc, so it builds with Wine's headers and the Linux libc alone.

**`/dev/9` rather than a device for each file.** Exposing the process's own 9front `/dev` covers draw, rio's per-window files, `snarf`, and whatever comes later with one directory, and a Linux process sees exactly what a 9front process in its place would. The name keeps clear of Linux's own `/dev` entries.

**Virtual desktop first.** Mapping each Windows top-level window to a rio window (through `/dev/wsys`) needs window management in both directions: moves, z-order, focus, and minimizing. That's most of `winex11.drv`'s size. One surface is enough to run real programs and to tell whether the rest is worth doing.

## Compatibility

No CLI flags, exit codes, `Machine.Options`, or sandbox defaults change. The Linux view gains `/dev/9`. `third_party/` is unchanged: the driver builds against Wine's headers fetched by `scripts/fetch.sh`, and `zig build wine` is a new, optional step. The driver is tied to one Wine release's driver interface (Wine 11.0 to start), so a Wine upgrade in a root needs the driver rebuilt, and possibly changed, for that release.

## Security

`/dev/9` gives a Linux process the files its 9front namespace already has, and nothing else: a 9front program in the same Proc could open the same files today. The gfx devices are masked without `--gfx`, so a Linux process can't open a window unless the machine was given one. The policy is unchanged.

## Done when

Demo: `h9 --gfx --root <alpine root with wine> wine notepad`, in a prefix with `Graphics=draw`, opens Notepad in the window, and typing and clicking work.

Integration cases, on the headless gfx backend, tagged `[wine-draw]`:

- `/dev/9` serves the process's 9front /dev, and has no draw files without gfx: a Linux fixture reads `/dev/9/winname` with gfx on, and gets `ENOENT` for `/dev/9/draw/new` with gfx off.
- a Wine program's window reaches the screen: a small Win32 test program (built with `zig cc -target x86_64-windows-gnu`) fills its client area with one color, and the test reads that color from the headless screen.
- mouse clicks and keys reach a Wine program: the test injects a click and a key, and the program prints the `WM_LBUTTONDOWN` position and the `WM_CHAR`.

The Wine cases need a root with Wine in it and skip without one, as the Alpine cases do.

## Implementation

1. `/dev/9` in devlinux, with its fixture case.
2. `scripts/fetch.sh` fetches Wine 11.0's source at a pinned hash, and `zig build wine` builds `winedraw.drv` and `winedraw.so` and installs them into a root.
3. The driver: registration, `UpdateDisplayDevices`, window surfaces and flushing, and the virtual desktop. The color case passes.
4. Input: the mouse and keyboard thread, the US layout, the cursor, and resizes. The input case passes.
5. The Notepad demo, and notes on what larger programs need next.

## Open issues

- Fetching Wine's source to build a driver of about a thousand lines is heavy. Alpine's `wine-dev` 11.0 ships `wine/unixlib.h` but not `wine/gdi_driver.h` or the other internal headers a driver includes. Vendoring just the headers the driver includes, at a pinned release, may be better.
- Whether a Linux root's Wine is the only target, or h9 should provide a Wine build with the driver in it, so the version always matches.
- Keyboard layouts beyond US, and keys that `/dev/kbd` reports as runes with no scan code.
- Whether the X server bridge in Rationale should come first, since it would cover both Wine and Linux X11 programs.
