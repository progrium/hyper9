---
slug: browser-gfx
title: Graphics on the browser host
status: draft
created: 2026-11-07
authors: [progrium]
depends: [12, 15]
areas: [kern, build, tests]
---

# Proposal: graphics on the browser host

## Abstract

The [browser host](0012-browser-host.md) gains the [gfx](0015-gfx.md) devices. A page passes a `<canvas>` to `createMachine({ gfx: { canvas } })`, and the machine's `/dev/draw`, `/dev/mouse`, `/dev/cursor` and `/dev/kbd` are that canvas, so rio and acme run in the page. The canvas moves into the Worker as an `OffscreenCanvas`, and a new GUI backend, `src/kern/gfx-web.c`, copies drawn rectangles from the screen image in wasm memory straight onto it. Input comes from the page's pointer and keyboard events. `/dev/snarf` is a buffer in the machine that the page fills on a paste event and copies out with the async clipboard API, so the guest can never read the clipboard without a paste by the user. Everything above the backend, including the lazy screen, the kbdfs `/dev/kbd`, closing and the device mask, is gfx's code, unchanged.

## Background

[gfx](0015-gfx.md) gives a native machine one host window. Its kernel side, `src/kern/gfx.c`, sits between drawterm's devices and one of drawterm's GUI backends, which implement a small interface from `kern/screen.h`:

- `screeninit` allocates `gscreen`, the screen image, and `attachscreen` hands it to devdraw
- `flushmemscreen(r)` copies a rectangle of `gscreen` to the window
- `screensize(r, chan)` reallocates `gscreen` on a resize, called from `term.c`'s resize kproc after `screenresize`
- `setcursor` and `mouseset` set the cursor's image and warp the pointer
- `getcolor` and `setcolor` serve 8-bit colour maps
- `clipread` and `clipwrite` are the clipboard
- input goes in through `absmousetrack(x, y, buttons, msec)` and `kbdkey(rune, down)`, from the backend's event thread

gfx also defines `h9.gfx`, `Machine.Options.gfx` and the `GfxNotBuilt`, `GfxInUse` and `GfxUnavailable` errors, and its headless backend is a screen in memory with test hooks.

The [browser host](0012-browser-host.md) runs h9 in a Web Worker on wasm32-wasi, with kernel processes as JSPI coroutines and 9front's 386 binaries on v86. Its Compatibility section leaves graphics out of scope: "a canvas backend for gfx in its own proposal". The page talks to the Worker by `postMessage`. A Worker has no DOM, so it can't see the page's events, set a CSS cursor or use `navigator.clipboard`, but it can draw on an `OffscreenCanvas` that the page transferred to it.

## Proposal

### API

`h9-web.js`'s `createMachine` takes a `gfx` option, mirroring `Machine.Options.gfx`:

```js
const m = await createMachine({
  root, memory, terminal,
  gfx: {
    canvas,              // an HTMLCanvasElement in the page
    clipboard: "page",   // "page" (default) or "private", as --gfx=noclip
    scale: 0,            // as --gfx-scale: 0 device pixels (default), 1 CSS pixels, N device pixels / N
  },
});
await m.run(["rio"]);
```

Without `gfx`, the machine is as today, and `#i`, `#m` and `#b` are masked. `h9-node` has no canvas, so `--gfx` there exits 125 with "graphics aren't built into this h9", the CLI's message for a build without a backend. One page can run several machines, one per Worker, and each can have its own canvas: `GfxInUse` is per process, and each Worker is a process.

### Build

`-Dgfx` gains `web`, the default and only GUI backend for web builds (`zig build web`). It builds `src/kern/gfx.c`, unchanged, with `src/kern/gfx-web.c` as the backend. `headless` still builds for the test module, so gfx's `[gfx]` backend cases run under Node on v86 as they do natively.

### The canvas

`createMachine` calls `canvas.transferControlToOffscreen()` and posts the `OffscreenCanvas` to the Worker with the machine's options. The page keeps the element, for its events, its CSS cursor and its size.

`gfx-web.c` implements the screen interface:

- **`screeninit`** asks the page for the canvas's size and allocates `gscreen` at that size as `XBGR32`, whose little-endian bytes are R, G, B and X, the order of an `ImageData` row. Then it calls `terminit`, as the other backends do.
- **`flushmemscreen(r)`** adds `r` to a dirty rectangle and, if no flush is pending, schedules one with the Worker's `requestAnimationFrame`. The flush runs in JavaScript, outside any coroutine. It takes the dirty rectangle's rows of `gscreen` from wasm memory, sets each pixel's X byte to 255 in a copy, and draws it with `putImageData`. So drawing is batched to the display's frame rate, and the kernel never waits for the canvas.
- **`screensize(r, chan)`** reallocates `gscreen` at the new size, as the X11 backend does.
- **`setcursor`** converts drawterm's 16×16 `Cursor` (its `set` and `clr` bitmaps and hot spot) into a PNG data URL and posts it to the page, which sets it as the canvas's CSS `cursor`. The arrow cursor is `default`.
- **`mouseset`** does nothing. A page can't move the pointer, so rio's warp to a new window, and acme's to a button it moved, don't happen. The pointer stays where the user left it.
- **`getcolor` and `setcolor`** keep the 8-bit colour map in a table, as the headless backend does, since `gscreen` is 32-bit.
- **`clipread` and `clipwrite`** are below.

`gscreen` stays in wasm memory, so devdraw draws in place as on native hosts, and only flushed rectangles cross into JavaScript.

### Size and scale

The page watches the canvas with a `ResizeObserver` and posts its content-box size in device pixels (`devicePixelContentBoxSize`, or the CSS size times `devicePixelRatio` where that's missing). `gfx-web.c` divides by the scale: 0 and 1 keep device pixels and CSS pixels, and N gives device pixels divided by N. It then calls `screenresize`, so `term.c`'s resize kproc reallocates the screen and devdraw tells rio, as a native window resize does. The canvas's drawing buffer is set to the same size, and CSS scales it back up to the element's size.

The default scale is 0, device pixels, which is what the X11 and Win32 backends draw in. Text is then small on a high-DPI display, as it is in drawterm. Pages that want it larger pass `scale: 1` or `scale: 2`. On a page, unlike macOS, there's no native look to match, so device pixels are the default here, where gfx defaults Cocoa to points.

### Input

**Delivery.** The page's events arrive in the Worker as messages, outside any coroutine, but `kbdkey` and `absmousetrack` take kernel locks and wake readers, and on native hosts they run on a kernel process. So `gfx-web.c` starts a kernel process, `gfxinput`, when the screen opens. It parks on a queue that the message handler fills and wakes, then calls `h9_kbdkey` and `absmousetrack` for each event, as the X11 backend's event thread does. The message handler itself never touches the kernel.

**Pointer.** The page listens for pointer events on the canvas, with pointer capture while a button is down, so a drag that leaves the canvas still ends with a button release:

- Coordinates are `offsetX` and `offsetY`, times the device pixel ratio, divided by the scale, so they match the screen's pixels.
- Buttons map from `PointerEvent.buttons`, whose bits are left 1, right 2, middle 4, to Plan 9's left 1, middle 2, right 4.
- The wheel gives buttons 8 (up) and 16 (down), one click per line or per 50 pixels of `deltaY`, as drawterm's backends do.
- For trackpads and one-button mice: a click with Alt (Option) held is button 2, and with Cmd held on macOS, or Ctrl elsewhere, is button 3. On macOS that's the Cocoa backend's mapping.
- The `contextmenu` event is cancelled on the canvas, so button 3 reaches rio.

**Keyboard.** The canvas gets `tabindex="0"` and receives keys only while it has focus, so the guest sees nothing typed into the rest of the page.

- `keydown` and `keyup` map `KeyboardEvent.key` to a Plan 9 rune: a single character is itself, and named keys map to `keyboard.h`'s (`Enter` is `\n`, `Backspace` `\b`, `Tab` `\t`, `Escape` `Kesc`, arrows `Kup` and so on, `Home`, `End`, `PageUp`, `PageDown`, `Insert`, `Delete` 0x7f, `F1` to `F12`, and `Shift`, `Control`, `Alt` and `Meta` as `Kshift`, `Kctl`, `Kalt` and `Kmod4`). `h9_kbdkey` then applies Ctrl, as on native hosts.
- Composed text (`isComposing`, or `key` longer than one character that isn't named) is taken from `compositionend` or `beforeinput`, rune by rune.
- `preventDefault` is called for every key the canvas handles, so Backspace, Tab and Ctrl-letter reach the guest instead of the page. Keys the browser reserves, such as Ctrl-W and Ctrl-T, never reach the page at all; those are documented. Cmd- and Ctrl-V are let through, so the paste event below fires.
- When the canvas loses focus, every key still held is released, as `keyup` for each, so rio's `/dev/kbd` doesn't see a key stuck down.

### The clipboard

A Worker can't use `navigator.clipboard`, and in a page reading it needs the user's permission or a user gesture. So `/dev/snarf` is always a buffer in the machine, `gfx.c`'s `noclip` buffer, and the page moves text across at the user's request:

- **In:** a `paste` event on the focused canvas (Ctrl-V or Cmd-V, or the browser's Paste menu) reads `clipboardData.getData("text/plain")` and posts it to the Worker, which replaces the snarf buffer. Then rio's or acme's own paste, button 2's menu or a 1-3 chord, pastes it. No permission prompt is involved, since the page reads only what the paste event hands it.
- **Out:** a write to `/dev/snarf` posts the text to the page, which calls `navigator.clipboard.writeText`. Browsers allow that while the page has focus. If it's refused, the text stays in the snarf buffer and the page fires a `snarf` event with the text, so an embedder can offer its own copy button.
- `clipboard: "private"` skips both, as `--gfx=noclip` does.

So the guest can read the user's clipboard only after the user pastes into the canvas. This differs from native gfx, where `/dev/snarf` reads the host clipboard directly. A native window is the user's own program, and the guest is sandboxed from the rest of the host. A page, though, may embed a guest that the user didn't choose, and browsers already treat clipboard reads as a permission for that reason.

### Closing

A page has no close button for a canvas. `h9-web.js` gains `machine.hangup()`, beside its `interrupt()` and `terminate()`, which posts `hangup` as gfx's window close does, and the page decides when to call it, such as from its own close button. `terminate()` still ends the Worker at once, as killing a native h9 does. When a run ends, the page gets the run's status. The canvas keeps the last frame until the page clears or removes it.

### The plan

`--print` with `--gfx` on a web build shows `gfx: web scale=N clipboard=page` (or `private`). The clipboard caveat reads "the guest can write the page's clipboard, and read what the user pastes into its canvas". gfx's caveat about drawing anything in the window applies here too, and the page decides where the canvas goes and how it's framed.

### Fonts in the root archive

rio and acme need their default fonts, which the browser host's trimmed root archive doesn't hold, and the 386 root's `/lib/font/bit` is 43 MB. The archive's list in the build gains rio, acme and the commands their windows run, and the fonts they open by default: 9front's `/lib/font/bit/vga` (about 0.5 MB), `lucsans/euro.8.font` and `lucm/unicode.9.font` with the subfonts they name. It also gains `/mnt/temp`, which rio needs. Other fonts come with a full root, which is browser-host's open issue.

## Rationale

**Why `OffscreenCanvas` in the Worker.** It lets `flushmemscreen` draw straight from wasm memory with no copy to another thread, and it's in every browser that has JSPI. Without it, each flush would post the rectangle's pixels to the page, a structured clone of up to 8 MB a frame at full screen on a high-DPI display, or need `SharedArrayBuffer` and cross-origin isolation, which browser-host avoids.

**Why `putImageData` rather than WebGL or WebGPU.** devdraw composites in memory, so the backend only uploads rectangles. `putImageData` of a dirty rectangle once a frame is enough for rio, acme and similar programs, and it has no context to lose. A GPU texture upload can replace it inside `gfx-web.c` if profiling ever shows a need, without changing anything above it.

**Why a kernel process for input.** `kbdkey` and `absmousetrack` lock, queue and wake, and drawterm's code assumes they run with `up` set. Calling them from the message handler would run kernel code outside any coroutine. `gfxinput` gives them the same context the native backends' event threads have, through browser-host's ordinary `h9_park`.

**Why the clipboard is paste-driven.** The alternatives were:

- **`navigator.clipboard.readText` from the page whenever the guest reads `/dev/snarf`.** The read would need a permission prompt at times the user didn't choose, or would fail outside a user gesture, and it would let the guest read the clipboard whenever it liked once permission was given.
- **A private buffer only.** Copy and paste between the guest and the rest of the page would be impossible, which makes acme much less useful.

The paste event gives the user an explicit action, the shortcut they already use, and needs no permission.

**Why device pixels by default.** It matches drawterm on X11 and Windows, and it's what 9front's fonts were drawn for. A page's CSS sizing then decides the on-screen size, as it does for any canvas.

**Why not warp the pointer with Pointer Lock.** Pointer Lock hides the system pointer and needs a user gesture and a visible exit. h9 would have to draw the cursor itself and track relative motion. rio works without warps; the pointer just doesn't jump to a new window.

**Alternatives rejected.**

- **Rendering in the main thread from a shared framebuffer.** This needs `SharedArrayBuffer` and cross-origin isolation, which limit where a page can embed h9 (browser-host's Rationale).
- **A DOM or SVG renderer.** devdraw's model is images and compositing in memory. A retained DOM tree would have to reinvent devdraw's layers and clipping.
- **Porting drawterm's own web or SDL backend.** drawterm has none for wasm, and SDL's emscripten port assumes emscripten's runtime, which browser-host doesn't use.

## Compatibility

- **API.** `createMachine` gains `gfx`, which passes `--gfx` (or `--gfx=noclip`) and `--gfx-scale` with the run's flags and posts the canvas, and the machine gains `hangup()`. `Machine.Options.gfx` and `h9.gfx` are unchanged; `h9.gfx.Backend` gains `web`, and `h9.gfx.main` calls `work` directly on the web host, as on non-macOS hosts.
- **CLI.** Unchanged. `h9-node --gfx` exits 125 as a build without graphics does.
- **Build.** `-Dgfx=web` is new, and is the default for wasm targets. Native builds are unchanged.
- **Root archive.** It gains rio, acme, their default fonts and `/mnt/temp`, about 1.5 MB.
- **Sandbox defaults.** As gfx: `#b`, `#i` and `#m` are masked without `gfx`.
- **Browsers.** `OffscreenCanvas` with a 2D context and `requestAnimationFrame` in Workers are required with `gfx`. Every browser with JSPI has both. `createMachine` rejects with "this browser can't draw from a Worker" if either is missing.
- **`third_party/`.** Unchanged. `gfx-web.c` is h9's own, written against `kern/screen.h`, and drawterm's devices are used as gfx uses them.

## Security

- **What the guest newly reaches,** only with `gfx`: one canvas it draws in, the pointer over it, the keyboard while it has focus, and the page's clipboard as described above. It can't read keys typed into the rest of the page, or the clipboard unless the user pastes into its canvas. It can write the clipboard while the page has focus, as any page script can.
- **Drawing.** The guest can draw anything in its canvas, including what looks like the page's own UI or a browser dialog. The canvas's size and place, and what frames it, are the embedder's. The docs say so, as gfx's caveat does for native windows.
- **No new imports reach the guest.** The canvas, events and clipboard are reached only by `gfx-web.c` and `h9-web.js`, through the screen interface and the input queue, as devdraw and the native backends reach a window.
- **Without `gfx`,** nothing changes: the devices are masked, and the Worker gets no canvas.

## Done when

- `zig build web` builds `gfx-web.c` by default, and the root archive holds rio, acme, their fonts and `/mnt/temp`.
- gfx's `[gfx]` backend cases pass under Node on v86 with the headless backend, as they do natively.
- Playwright cases in Chromium on the demo page, tagged `[browser-gfx]`:
  - `test "a draw client's image reaches the canvas [browser-gfx]"`: the canvas's pixels show the rectangle the `draw` fixture draws.
  - `test "rio starts, and a window's rc runs a command typed into it [browser-gfx]"`: typed keys run `echo hi > /dev/snarf` in a rio window, and the page's `snarf` event, or the clipboard where Playwright grants it, gets `hi`.
  - `test "a paste into the canvas reaches /dev/snarf [browser-gfx]"`
  - `test "resizing the canvas resizes the screen [browser-gfx]"`: after the canvas's CSS size changes, `/dev/draw/new` reports the new size.
  - `test "keys typed outside the canvas don't reach /dev/kbd [browser-gfx]"`
  - `test "machine.hangup posts hangup and ends the run [browser-gfx]"`
- **Demo:** the demo page from `zig build web` has a "rio" button that starts `rio -i 'window acme'` in a canvas, in Chrome. Text snarfed in acme pastes in another browser tab, and text copied elsewhere pastes into acme with Ctrl-V and then button 2's paste.

## Implementation

1. **Fonts and the archive.** Add rio, acme, their default fonts and `/mnt/temp` to the root archive's list, and run gfx's headless `[gfx]` cases under Node on v86. This checks the kernel side, lazy screen and kbdfs keys included, on coroutines before any browser work.
2. **The canvas backend.** `gfx-web.c`: `screeninit`, `flushmemscreen` with the frame-batched flush, `screensize`, colour maps, and `-Dgfx=web` in the build. The draw fixture's case passes.
3. **Input.** The `gfxinput` kernel process, the page's pointer and keyboard handlers, focus and key release, and composition. The rio case passes.
4. **The clipboard and cursor.** Paste in, `writeText` out with the `snarf` event fallback, and `setcursor` as a CSS cursor. The paste case passes.
5. **Resize, close and the plan.** The `ResizeObserver` path, `machine.hangup`, and the `gfx:` line and caveats. The remaining cases pass.
6. **Docs.** The demo page's rio button, the README's browser section, and DESIGN.md's graphics and web host sections. Set `status: implemented`.

## Open issues

- **Touch.** Pointer events cover touch too, but with no buttons beyond the first and no hover. A touch page could use the long-press as button 3 and a two-finger tap as button 2. That needs trying on a tablet before it's specified.
- **Several canvases from one machine.** Plan 9 has one screen per terminal, and rio gives windows within it. A page that wants each rio window as its own element would need a different design (a rio-like file server in the page). That would be its own proposal.
- **Frame cost at full screen.** A 4K canvas in device pixels is 33 MB of pixels. A full-screen redraw at that size copies all of it each frame, which may be too slow. The fixes would be a larger default scale on such displays, or a texture upload. The Playwright demo on a high-DPI display will tell.
