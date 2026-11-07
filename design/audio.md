---
slug: audio
title: Audio (--audio)
status: draft
created: 2026-11-07
authors: [progrium]
depends: [12]
areas: [cli, kern, build, sandbox, tests]
---

# Proposal: audio (--audio)

## Abstract

`--audio` gives a machine the host's sound output as `/dev/audio` and `/dev/volume`, served by drawterm's devaudio (`#A`) over a host backend. On Linux and Windows, the backends are drawterm's own: PipeWire or ALSA, and Win32, picked by a build option as `-Dgfx` picks a GUI. drawterm has no Core Audio backend, so macOS gets a small one of h9's own. On the [browser host](0012-browser-host.md), a Web Audio backend sends samples to an AudioWorklet in the page, and a write to `/dev/audio` parks its coroutine until the worklet has room. Playback is all `--audio` grants. Recording needs `--audio=record`. Without either, `#A` is masked, as `#i` is without `--gfx`.

## Background

### h9 today

- **The device is built, but has no sound.** `build.zig` compiles drawterm's `devaudio.c` with `devaudio-none.c`, as drawterm's `Make.config` does with `AUDIO=none`, and `src/kern/devtab.c` lists `audiodevtab`. Every backend call in `devaudio-none.c` raises "no audio support", so opening `#A/audio` fails, and so does reading `#A/volume`.
- **It isn't bound or masked.** Nothing binds `#A`, and it isn't in the device mask, so a guest can attach it, but can do nothing with it.

### drawterm's devaudio

`kern/devaudio.c` serves a directory with two files:

- **`audio`**: 16-bit little-endian stereo PCM at 44100 Hz, 9front's default format, the one `play`, `audio/pcmconv` and the decoders write. A write plays samples, and a read records them. It can be open once at a time, in one mode, process-wide: a second open fails with `Einuse`.
- **`volume`**: text, in 9front's format (`audio out 50`, `speed 44100`). Reads list each level the backend reports, and writes parse `audio 70`, `left 30` and so on.

The device calls a small interface (`kern/devaudio.h`) that each backend implements: `audiodevopen`, `audiodevclose`, `audiodevread`, `audiodevwrite`, `audiodevgetvol` and `audiodevsetvol`. Its state is global to the host process, like devdraw's.

The backends in `third_party/drawterm/kern` and what they do:

| Backend | Host | Library | Plays | Records | Volume | A full buffer blocks in |
| --- | --- | --- | --- | --- | --- | --- |
| `pipewire` | Linux (drawterm's default there) | `libpipewire-0.3` | yes | no | errors | the kernel's `sleep`, which a note interrupts |
| `alsa` | Linux | `libasound` | yes | yes | `speed` only | `snd_pcm_writei`, a host call |
| `win32` | Windows | `winmm` (`waveOut`) | yes | no | yes | an `osmsleep(50)` loop |
| `unix` | Linux and BSD | none: OSS `/dev/dsp` | yes | no | yes | `write`, a host call |
| `sndio` | OpenBSD | `libsndio` | yes | no | no | `sio_write`, a host call |
| `sun`, `haiku` | | | | | | |
| `none` | everywhere else, including macOS | | | | | |

Things to note:

- **No macOS backend.** drawterm's `Make.osx-cocoa` sets `AUDIO=none`.
- **ALSA opens the microphone on every open.** `audiodevopen` opens both the playback and capture PCMs, whatever mode `/dev/audio` is opened in, so a program that only plays still opens the host's capture device.
- **Writes can't always be interrupted.** ALSA, OSS and sndio block in a host call, and Win32 polls with a host sleep. drawterm's `sleep` raises `Eintr` when a note is pending, but these never reach it, so a large write runs to the end before a note is seen. Only the PipeWire backend waits in the kernel.
- **Linking.** PipeWire and ALSA are shared libraries, so, like X11 for [gfx](0015-gfx.md), they need a glibc target. h9's Linux releases are static musl.
- **A PipeWire bug.** `on_process` returns with `pwstate.lk` held when `pw_stream_dequeue_buffer` gives no buffer, so the next write deadlocks. It's an upstream fix to send.

## Proposal

### The flag and the options

| Flag | Meaning |
| --- | --- |
| `--audio` | Binds `#A` at `/dev`: `/dev/audio` plays on the host's default output, and `/dev/volume` sets the machine's own level |
| `--audio=record` | The same, and `/dev/audio` can also be opened for reading, which records from the host's default input |

`Machine.Options` gains `audio: ?Audio = null`, where `Audio` is `struct { record: bool = false }`. The device's state is global, so at most one machine in a process can have audio at a time. `Machine.init` fails with:

- `AudioNotBuilt` when this h9 has no audio backend. The CLI prints "audio isn't built into this h9" and exits 125.
- `AudioRecordNotBuilt` when `record` is asked for and the backend can't record (PipeWire and Win32, for now). The CLI prints "this h9's audio backend can't record" and exits 125.
- `AudioInUse` when another machine in the process has audio.

A missing host sound server isn't an `init` error. The backend opens the host's device only when the guest opens `/dev/audio`, as drawterm does, so a run that never plays never touches it, and an open that can't reach it fails with the backend's message ("could not connect pipewire stream"). `--check` reports the backend, and on Linux whether it can reach the sound server, without playing anything.

### Devices and the namespace

With `--audio`, the namespace builder appends `#A` to `/dev` after the console and, with `--gfx`, the window's devices:

```text
  bind -a '#A' /dev
```

Without `--audio`, `A` joins the device mask, so a guest can't attach `#A`, even in a build with a backend.

**h9's wrapper.** As gfx wraps devdraw in `h9drawdevtab`, a new `src/kern/audio.c` wraps devaudio in `h9audiodevtab`, which `src/kern/devtab.c` lists in place of `audiodevtab`. The wrapper:

- **Refuses recording without the grant.** An open of `audio` for reading or `ORDWR` fails with `Eperm` unless the machine has `record`. The backend never sees it.
- **Chooses which host streams open.** Before `audiodevopen`, it records the open's mode. ALSA's backend is compiled with a forced-include header, `src/kern/audio-alsa.h`, that redirects `snd_pcm_open` to `h9_snd_pcm_open`. That opens ALSA's `null` PCM for whichever direction the open doesn't use. So an open for writing never opens the host's capture device, and an open for reading never opens playback. The vendored file stays unmodified, as with gfx's `gfx-gui.h`.
- **Writes in slices.** It passes a write to `audiodevwrite` in slices of 4096 bytes, about 23 ms of sound, and checks for a pending note between slices, raising `Eintr` if there is one. A note then reaches a writer within a slice and a backend buffer's time, whatever the backend, and a write that's interrupted returns an error with the earlier slices already played, as 9front's driver does.
- **Keeps the volume itself.** `/dev/volume` is served by the wrapper, not the backend. It keeps `audio` and `pcm` levels for the machine, from 0 to 100, both 100 at first, and scales samples in the write path before they reach the backend. A read reports them, along with `speed 44100`. A write of `speed` other than 44100 fails, and the other names in devaudio's table (`treb`, `bass`, `mic` and so on) are accepted and ignored. The guest never changes the host's mixer or system volume, and `/dev/volume` reads the same on every backend, including PipeWire, whose own `audiodevgetvol` raises an error.
- **Drains on close.** Closing `/dev/audio` after writing waits, interruptibly, until what's buffered has played, as ALSA's `snd_pcm_drain` does, so `play x; echo done` prints after the sound ends. The buffer is short, so this takes at most a fraction of a second.

### Build

`-Daudio=coreaudio|win32|pipewire|alsa|web|headless|none` picks the backend, as `-Dgfx` does:

| Host | Default | Notes |
| --- | --- | --- |
| macOS | `coreaudio` | `src/kern/audio-coreaudio.c`, below. Links the AudioToolbox and CoreAudio frameworks, with the macOS SDK, as the Cocoa GUI does |
| Windows | `win32` | drawterm's `devaudio-win32.c`, linking `winmm` from Zig's MinGW |
| Linux | `none` | `pipewire` builds drawterm's `devaudio-pipewire.c` against a glibc target and the system's `libpipewire-0.3`. `alsa` builds `devaudio-alsa.c` against `libasound`, and can record. A Linux desktop build passes `-Dgfx=x11 -Daudio=pipewire` |
| web | `web` | `src/kern/audio-web.c` and the worklet, below |
| any | | `headless` is for tests, below |

`devaudio-none.c` stays as the `none` backend. `--version` lists the audio backend.

**The macOS backend.** `src/kern/audio-coreaudio.c` implements `devaudio.h` with an output AudioUnit (`kAudioUnitSubType_DefaultOutput`), set to the device's stream format of 16-bit stereo at 44100 Hz, so Core Audio does any conversion to the hardware's rate:

- A single-producer, single-consumer ring of about 100 ms sits between the writer and the unit's render callback. The callback runs on Core Audio's real-time thread, which isn't a kernel process and mustn't take locks, so it only copies from the ring with atomic indices, and fills with silence when it's empty.
- `audiodevwrite` copies what fits into the ring. When it's full, the writer waits with `tsleep` for a quarter of the ring's length and checks again. So the real-time thread never calls into the kernel, and a note interrupts the wait.
- Recording, with `record`, uses an AUHAL input unit on the default input device, with its own ring the other way round, read by `audiodevread`. macOS asks the user for microphone access the first time, through its privacy controls. A signed h9 needs the `com.apple.security.device.audio-input` entitlement for that, which is added to `h9.entitlements`.
- `audiodevgetvol` and `audiodevsetvol` do nothing, since the wrapper keeps the volume.

**The headless backend,** `src/kern/audio-headless.c`, plays into memory. `src/audio.zig` exposes test hooks: read what was played, set the rate at which the backend consumes samples (including 0, to fill the buffer and hold it full), and queue samples for recording. It's built for `zig build test`, so the cases below run on every host and in CI without a sound device.

### The browser host

On the browser host, the machine runs in a Web Worker, and a Worker has no `AudioContext`. So the sound goes through the page.

**API.** `h9-web.js`'s `createMachine` takes an `audio` option, mirroring `Machine.Options.audio`:

```js
const m = await createMachine({
  root, memory, terminal,
  audio: true,                 // or { record: true }, or { record: mediaStream }
});
```

`createMachine` creates an `AudioContext({ sampleRate: 44100 })` in the page and adds an `AudioWorkletNode` running `h9-audio-worklet.js`, which `h9-web.js` ships alongside it and loads with `audioWorklet.addModule`. It connects the node to the context's destination. Then it creates a `MessageChannel`, gives one port to the worklet and transfers the other to the Worker, so samples go from the Worker to the audio thread directly, without passing through the page's main thread. A page can pass its own `context` in the option to share an `AudioContext` it already has.

**The backend,** `src/kern/audio-web.c`, implements `devaudio.h`:

- **Writing.** The worklet keeps a queue of up to 200 ms of samples and tells the Worker how much room it has: once when the node starts, and again each time it has played another 20 ms. The Worker keeps that as credit. `audiodevwrite` copies as much as the credit allows into a new `ArrayBuffer`, posts it to the worklet as a transferable, and takes the credit. When there's no credit, it sleeps on a Rendez with the kernel's `sleep`, which on the browser host parks its coroutine through `h9_park`, so the rest of the machine keeps running and a note interrupts it.
- **Waking a writer.** The port's message handler runs in the Worker outside any coroutine, so it doesn't call into the kernel. It adds the credit and unparks a kernel process, `audiopump`, started when `/dev/audio` is opened, which calls `wakeup` on the writer's Rendez. That's browser-gfx's pattern for input (its `gfxinput` process), so kernel code only ever runs in a coroutine.
- **The worklet** converts each 16-bit interleaved buffer to the two 32-bit float channels Web Audio uses, and plays it out in 128-frame render quanta. When its queue is empty, it outputs silence and posts nothing until it has room to report.
- **Closing** posts a drain message. The worklet answers once its queue is empty, which wakes the closer through `audiopump`.

So a guest can never get more than about 200 ms ahead of the speakers, the Worker never busy-waits, and nothing needs `SharedArrayBuffer` or cross-origin isolation, which [browser-host](0012-browser-host.md) avoids.

**Autoplay.** Browsers start an `AudioContext` suspended until the user interacts with the page. While it's suspended, the worklet plays nothing and reports no room, so a write parks until the context runs, and no samples are dropped. `createMachine` resumes the context on the page's first `pointerdown` or `keydown`. If the guest opens `/dev/audio` while the context is suspended, the machine fires an `audioblocked` event, so the page can show a "click to enable sound" control that calls `m.audio.resume()`.

**Recording,** with `{ record: true }`, calls `navigator.mediaDevices.getUserMedia({ audio: true })` the first time the guest opens `/dev/audio` for reading, so the browser's permission prompt appears then, and a refusal fails the open with "microphone access denied". The page can instead pass a `MediaStream` it already has as `record`, and no prompt comes from h9. The stream goes through a `MediaStreamAudioSourceNode` into the worklet, which converts it to 16-bit interleaved samples and posts them to the Worker in 20 ms buffers. `audiodevread` parks until there's data. The worklet keeps at most 1 s of recorded sound, dropping the oldest if the guest doesn't read, so a guest that stops reading doesn't grow the page's memory.

**`h9-node`** has no Web Audio, so it's built with `none`, and `--audio` there exits 125 as on a build without a backend.

### Relation to gfx

Audio doesn't depend on [gfx](0015-gfx.md) or [browser-gfx](browser-gfx.md) (proposed in #58). It follows their shape: a device that's built in but masked until a flag grants it, a wrapper in `src/kern/` around drawterm's device, a `-D` build option per host with a headless backend for tests, and an error naming the backend when a machine asks for something this build doesn't have. A machine can have both, and `h9 --gfx --audio rio` gives rio's programs a window and sound.

### The plan

`--print` gains an `audio:` line, `audio: pipewire playback` or `audio: coreaudio playback,record`, when `--audio` is given, and the device mask shows `#A` when it isn't. Caveats:

- with `--audio`: "the guest can play sound on the host's default output"
- with `--audio=record`: "the guest can record from the host's default input, such as a microphone"

`--sandbox` refuses `--audio=record` with a usage error (exit 2), as it refuses `--host-cmd`. Playback is allowed there, since it's output only.

## Rationale

**drawterm's backends on Linux and Windows.** They're vendored, they're what drawterm users on those hosts already get, and they fit devaudio's interface. Their faults, the microphone opened on every ALSA open and writes that ignore notes, are fixed in h9's wrapper and a redirect header, without touching `third_party/`.

**An h9 backend on macOS.** drawterm has none to reuse. Core Audio's output unit is a pull model, so a ring and a real-time callback that never locks is the standard shape, and polling with `tsleep` keeps the real-time thread out of the kernel. `AVAudioEngine` would need Objective-C and gain nothing here. AudioQueue would also work, but owns its buffers in a way that makes backpressure less direct.

**Polling on macOS, not a wakeup from the callback.** Waking a Rendez takes kernel locks, which a real-time audio thread mustn't do. A host semaphore signalled by the callback, with a kernel process waiting on it to call `wakeup`, would work too, at the cost of a thread. A quarter of a 100 ms ring is fine-grained enough for playback, and costs a few wakeups a second.

**Linux audio is a build option, not the default.** As with X11 for gfx, PipeWire and ALSA need glibc and dynamic linking, and Linux releases stay the static `h9`. The OSS backend links nothing and would work in a static build, but `/dev/dsp` is missing on most current distributions unless an emulation layer such as `osspd` runs, so it's not offered.

**PipeWire as the Linux default, ALSA for recording.** PipeWire is drawterm's Linux default, it's the sound server on current desktops, and it's the only Linux backend that waits in the kernel. Its backend can't record, though. ALSA can, and also reaches PipeWire through `pipewire-alsa`, so a build that needs recording uses `-Daudio=alsa` until the PipeWire backend gains capture.

**The volume kept in h9, not the host mixer.** devaudio's backends set the host's mixer or stream volume where they can. A sandboxed guest turning the host's volume up isn't something to grant, and keeping the level in the write path makes `/dev/volume` behave the same everywhere.

**Playback by default, recording as a separate grant.** Playing sound reveals nothing about the host. A microphone is a sensor, like reading a file, and needs a grant of its own, and the host's or the browser's own permission prompt on top.

**AudioWorklet and transferred buffers, not `SharedArrayBuffer`.** A shared ring between the Worker and the worklet would avoid the messages, but needs cross-origin isolation, which limits where a page can embed h9. A transferred buffer every 20 ms is cheap. `ScriptProcessorNode` is deprecated and runs on the main thread. Scheduling `AudioBufferSourceNode`s from the page would need the page's main thread on the path and gives no backpressure.

**Backpressure, not dropping samples.** `play` and the decoders expect a write to block until the device takes the samples, as on 9front. Dropping when the worklet is full would make them run as fast as they can decode and play only the last fraction of a second.

**The worklet's port in the Worker, not the page's.** Samples then cross from the Worker to the audio thread in one hop, and a busy main thread can't make sound stutter.

**Not in this proposal:** 9front's `/dev/audioctl` and `/dev/audiostat`, other formats or rates, choosing a host device other than the default, and several machines sharing the host's output through a mixer.

## Compatibility

- **CLI:** `--audio` and `--audio=record` are new. Exit 125 when they can't be honoured, and 2 for `--audio=record` with `--sandbox`.
- **`Machine.Options`:** `audio` is new, with the errors above.
- **Sandbox defaults:** `#A` is masked in every machine without `--audio`. Nothing could use it before, since every backend call failed.
- **Build and releases:** macOS and Windows builds gain an audio backend by default, with AudioToolbox and CoreAudio, or `winmm`. Linux builds and releases are unchanged unless `-Daudio` is given. Web builds gain the worklet file.
- **Browser API:** `createMachine` gains `audio`, and the machine gains `audio.resume()` and the `audioblocked` event.
- **Vendored tree:** unchanged. `devaudio-pipewire.c`, `devaudio-alsa.c` and `devaudio-win32.c` are compiled as they are, ALSA's with a forced-include redirect.

## Security

- **What the guest newly reaches,** only with `--audio`: the host's default output, at the level it sets for itself in `/dev/volume`. It can't change the host's volume or pick another device.
- **Recording,** only with `--audio=record`: the host's default input. On macOS and in the browser, the OS or the browser asks the user first. On Linux and Windows there's no prompt beyond h9's flag, so the plan's caveat says so, and `--sandbox` refuses it.
- **No microphone with playback alone.** h9's wrapper refuses opens for reading, and ALSA's redirect keeps the capture device closed when playing.
- **Between machines,** only the machine with audio has `#A` unmasked, and `AudioInUse` keeps a second from opening the host's device.
- **The page.** On the browser host, the sound and the microphone go through the page's `AudioContext`, under the browser's autoplay and permission rules. The guest reaches neither except through `audio-web.c`.

## Done when

Backend cases in `tests/backends.zig`, on the headless backend, tagged `[audio]`:

- `test "--audio binds /dev/audio and /dev/volume [audio]"`
- `test "samples written to /dev/audio reach the backend in order [audio]"`
- `test "a write blocks while the backend's buffer is full and finishes as it drains [audio]"`
- `test "a note interrupts a write blocked on a full buffer [audio]"`
- `test "closing /dev/audio waits for buffered samples to play [audio]"`
- `test "with --audio, opening /dev/audio for reading fails [audio]"`
- `test "with --audio=record, reading /dev/audio returns the backend's samples [audio]"`
- `test "/dev/volume scales samples and reports the machine's level [audio]"`
- `test "a second machine in the process gets AudioInUse [audio]"`

Integration cases, on any build:

- `test "without --audio, #A is masked [audio]"`
- `test "--audio on a build without audio exits 125 [audio]"`, in a `-Daudio=none` build.
- `test "--sandbox refuses --audio=record [audio]"`

The backend cases also run under Node on v86 with the headless backend, and Playwright cases in Chromium, on the demo page with autoplay allowed:

- `test "samples written to /dev/audio reach the AudioWorklet [audio]"`: the worklet's test hook counts the frames it played.
- `test "writes park until the AudioContext is resumed [audio]"`: with the context suspended, a write doesn't finish and `audioblocked` fires. After `m.audio.resume()`, it finishes.

Demos, by hand, one per backend: `h9 --audio play song.mp3` plays on macOS, Windows and Linux (PipeWire), and Ctrl-C stops it at once. `h9 --audio=record rc -c 'dd -if /dev/audio -of /tmp/r -count 400; cat /tmp/r > /dev/audio'` plays back what was recorded, on macOS and on Linux with `-Daudio=alsa`. On the demo page, a "play" button plays a WAV in Chrome after one click.

## Implementation

1. `src/kern/audio.c` with `h9audiodevtab`: the recording check, sliced writes, the volume, draining. `-Daudio`, the masking of `#A` without `--audio`, and `devaudio-none.c` as `none`. The masking case passes.
2. `src/kern/audio-headless.c` and `src/audio.zig`'s test hooks, `Machine.Options.audio`, the `/dev` bind and `AudioInUse`. The headless cases pass.
3. `--audio` and `--audio=record` in `src/cli.zig`, the plan's `audio:` line and caveats, `--sandbox`'s refusal, `--version` and `--check`.
4. Win32: `-Daudio=win32` as the Windows default. The Windows demo works.
5. macOS: `audio-coreaudio.c`, the frameworks, and the entitlement. The macOS demos work.
6. Linux: `-Daudio=pipewire` and `-Daudio=alsa` with `audio-alsa.h`. The Linux demos work. Send drawterm the `on_process` fix.
7. Web: `audio-web.c`, `audiopump`, `h9-audio-worklet.js`, `createMachine`'s `audio`, autoplay handling, and recording. The Playwright cases pass.
8. README and MANUAL: `--audio` and the build option. DESIGN.md: the boot sequence's binds and device mask, the CLI flag table, and the web host's section. Set `status: implemented`.

## Open issues

- **`/dev/audiostat`.** 9front's driver also serves `audioctl` and `audiostat`, whose `delay` lets a player keep video in step with sound. drawterm's devaudio has neither. The wrapper could serve `audiostat` from the backend's buffered count if a program needs it.
- **Recording on PipeWire and Windows.** Both backends would need capture added, in h9's own code or upstream in drawterm.
- **Latency.** The ring and the worklet's queue sizes (100 ms and 200 ms) are guesses. Games want less, and slow machines may underrun with less. They may need to be options.
- **Device choice.** Should `--audio=DEVICE` pick a host output other than the default?
