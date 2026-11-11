# Running Claude Code in the browser

h9's web host can run Claude Code, Anthropic's command-line coding agent,
in a browser tab. Claude Code is shipped as a Linux binary, and in the tab
it runs on ha64, h9's own arm64 CPU, in a Web Worker. This guide covers
what such a page needs: the root archive, the memory size, the guest's
environment, and the terminal.

It assumes you've built the web host (`zig build web`, which puts `h9.wasm`,
`h9-web.js`, and the rest in `zig-out/web`) and read the
[browser host](../design/0012-browser-host.md) section of the
[manual](../MANUAL.md) on `createMachine`. The browser needs JavaScript
Promise Integration, which is in Chrome and Edge 137 and later.

## Contents

1. [A first page](#a-first-page)
2. [The root archive](#the-root-archive)
3. [Memory](#memory)
4. [The guest's environment](#the-guests-environment)
5. [The terminal](#the-terminal)
6. [Network and signing in](#network-and-signing-in)
7. [What to expect](#what-to-expect)

## A first page

This page runs Claude Code from `cc.h9a`, an archive beside it (see
[The root archive](#the-root-archive)), and shows its output in a `<pre>`:

```html
<!doctype html>
<meta charset="utf-8">
<pre id="out"></pre>
<script type="module">
import { createMachine } from './h9-web.js';

const out = document.getElementById('out');
const dec = new TextDecoder();
const m = await createMachine({
  root: 'cc.h9a',
  arch: 'arm64',
  memory: '1G',
  tty: true,
  terminal: { write: (b) => { out.textContent += dec.decode(b, { stream: true }); } },
});
const env = [
  'TERM=xterm-256color',
  'HOME=/root',
  'BUN_JSC_useConcurrentGC=0',
  'BUN_JSC_useJIT=0',
];
const code = await m.run([
  '--net', 'disable',
  ...env.flatMap((e) => ['--env', e]),
  '/usr/local/bin/claude',
]);
out.textContent += `\nexited ${code}\n`;
</script>
```

Serve `zig-out/web` with the page and the archive in it, over any static
HTTP server; no special headers are needed. A `<pre>` doesn't understand
terminal escapes, so for the full-screen interface, use a terminal emulator
such as xterm.js (see [The terminal](#the-terminal)). Type into the machine
with `m.input(text)`, and send Ctrl-C with `m.interrupt()`.

## The root archive

The page's root is an h9 root archive (`.h9a`) built from an arm64 Linux
root that has Claude Code's musl build in it. Alpine's minirootfs is
enough: Claude Code links only against musl's libc.

1. Unpack Alpine's arm64 minirootfs into a directory, such as
   `.local/linux/alpine-arm64`.
2. Put Claude Code's `linux-arm64-musl` binary at `usr/local/bin/claude`
   in it, and make it executable.
3. Write `root/.claude.json` with onboarding done and the working directory
   trusted, so the first run doesn't stop at the setup screens:

   ```json
   {
     "hasCompletedOnboarding": true,
     "projects": { "/mnt/term/cwd": { "hasTrustDialogAccepted": true } }
   }
   ```

4. List what goes in the archive, one path per line. A path ending in `/`
   is an empty directory, used for a mount point:

   ```
   dev/
   proc/
   sys/
   tmp/
   mnt/term/cwd/
   sbin/
   usr/sbin/
   etc/os-release
   etc/passwd
   etc/group
   lib/ld-musl-aarch64.so.1
   lib/libc.musl-aarch64.so.1
   bin/busybox
   usr/local/bin/claude
   root/.claude.json
   ```

5. Pack it with `tools/webroot.zig`:

   ```sh
   zig build-exe -OReleaseSafe -femit-bin=.local/webroot tools/webroot.zig
   .local/webroot .local/linux/alpine-arm64 cc.list zig-out/web/cc.h9a
   ```

The archive is about 290 MB, almost all of it the `claude` binary. The page
fetches it once per machine, so serve it with caching. The root is
read-only: what Claude Code writes, such as its updated `~/.claude.json`,
goes to an in-memory overlay and is gone when the page closes. To add files
before or while it runs, such as a project to work on, use `m._put(path,
data)`, or stack more archives with `layers`.

## Memory

Pass `memory: '1G'`. The default, 256 MiB, isn't enough to load the binary.
1G leaves room for its heap, and more doesn't make it faster.

The tab needs more than the guest gets, because the archive, h9's own heap,
and compiled code are all on top of it. Expect the tab to use about 2 GB.
The most `memory` can be is `'2G'`.

## The guest's environment

Claude Code's environment is set with `--env NAME=value` in `m.run`'s
argv, one flag per variable. `createMachine`'s `env` option is something
else: it's h9's own environment, which holds the emulator's tuning knobs,
and Claude Code never sees it.

| Variable | Value | Why |
|---|---|---|
| `TERM` | `xterm-256color` | Claude Code draws its full-screen interface for this terminal type. |
| `HOME` | `/root` | Where it finds `.claude.json` and `.claude/`. |
| `BUN_JSC_useConcurrentGC` | `0` | The tab gives the guest one CPU, and JavaScriptCore's concurrent collector stalls the main thread on one CPU. Off, boot is about 40% faster. |
| `BUN_JSC_useJIT` | `0` | JavaScriptCore's JIT writes arm64 code that h9 must translate again, and on one CPU that costs more than it saves. Off, boot is about 10% faster on top of the line above. |
| `ANTHROPIC_API_KEY` | your key | To sign in with an API key. See [Network and signing in](#network-and-signing-in). |

Claude Code's own variables work as they do anywhere else. Avoid
`DISABLE_TELEMETRY` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` unless
you need them, since both make it do more work before it shows its
prompt.

## The terminal

With `tty: true`, Claude Code sees a terminal: `isatty` is true, and it can
set raw mode. The terminal's `setRaw(on)` callback says when it does. In
raw mode, pass every key through to `m.input` as it's typed, with no line
editing of your own. The guest sees an 80-by-24 window, and resizing the
page's terminal doesn't resize the guest's.

Wire a terminal emulator in both directions:

```js
const term = new Terminal({ cols: 80, rows: 24 });
term.open(document.getElementById('term'));
const m = await createMachine({
  root: 'cc.h9a', arch: 'arm64', memory: '1G', tty: true,
  terminal: { write: (b) => term.write(b) },
});
term.onData((s) => m.input(s));
```

Claude Code queries the terminal at startup, and xterm.js answers those
queries through `onData`.

## Network and signing in

A tab can't open sockets, so the machine has no network of its own: run it
with `--net disable`, and Claude Code shows "Not logged in" at its prompt.
To reach Anthropic's API, mount a host's `/net` over a WebSocket, as in
the manual's section on serving `/net`. One h9 on a host serves it:

```sh
host$ h9 --serve ws://127.0.0.1:5640/ --serve-root /net --serve-net --serve-origin https://your.page
```

Add `--serve-token` when it listens beyond loopback.

The page mounts it before starting Claude Code. `wsmount` is a 9front
command, so the page stacks an arm64 9front layer at `/9` and names it
with a second `--root /9`. The layer is `nine-arm64.h9a`, which
`zig build web` puts in `zig-out/web` once `zig build slim -Darch=arm64`
has made the arm64 slim root:

```js
const m = await createMachine({
  root: 'cc.h9a',
  layers: [{ url: 'nine-arm64.h9a', at: '/9' }],
  arch: 'arm64', memory: '1G', tty: true, terminal,
});
await m.run([
  '--root', '/9',
  ...env.flatMap((e) => ['--env', e]),
  '--env', `ANTHROPIC_API_KEY=${key}`,
  '/bin/busybox', 'sh', '-c',
  '/9/bin/wsmount -b ws://127.0.0.1:5640/ /net && exec /usr/local/bin/claude',
]);
```

Claude Code's HTTPS goes through the mounted `/net`, under the serving h9's
`--net` and `--net-allow`. Everything it sends, including the API key,
passes through that host, so serve `/net` only from a machine you trust.

## What to expect

On a recent laptop or a 4-core cloud VM, Claude Code takes about 40 s to
reach its prompt in the tab with the settings above. Natively on the same
machine it takes about 15 s. `claude --version` takes about 4 s, and
`claude --help` about 13 s.

The first run in a page pays for compiling the hottest code to wasm, and
nothing is kept between page loads. Once it's at the prompt, typing and
redrawing are interactive, and requests take as long as the network and
the API do.
