---
slug: js-runtime
title: A Node-compatible JavaScript runtime on the browser host
status: draft
created: 2026-11-11
authors: [progrium]
depends: [browser-host, linux-personality, websocket-9p]
areas: [web, kern, linux, tests]
---

# Proposal: A Node-compatible JavaScript runtime on the browser host

## Abstract

On the browser host, `node` runs JavaScript on the browser's own V8, not on an emulated CPU. A JS process is an ordinary h9 process in the Linux personality, with a pid, file table, cwd, root, credentials, notes, and policy. Its code runs in a Worker of its own, and a Node-compatible runtime, `h9node`, turns Node's API into Linux syscalls that h9's kernel serves. So `node` shares the machine's namespace, pipes, and processes with everything else. A script's `child_process.spawn('git')` starts the emulated git, and `busybox cat` sees the file a script just wrote. `node script.js | wc -l` is a normal pipeline, and `#!/usr/bin/env node` scripts just work. Synchronous calls (`fs.readFileSync` and `spawnSync`) block the JS Worker on h9: through a `SharedArrayBuffer` when the page is cross-origin isolated, and through a synchronous request to a service worker when it isn't, so pages keep working without COOP and COEP. The network goes only through h9, under the machine's net policy. The runtime is JavaScript and h9's existing Linux syscall table, plus one new kind of process. No V8, Node, or Bun is compiled to wasm.

## Background

- **JS under emulation is slow.** h9 runs Linux binaries in the browser on ha64's wasm JIT, so a JS program means emulating a whole JS engine, and its JIT on top. Claude Code, a Bun program, reaches its prompt in 136 s in Chromium against 14 s natively. Most of that time is spent emulating JavaScriptCore while it parses and compiles JavaScript, which the browser could run itself.
- **The browser's V8 is right there.** A prototype on 2026-11-11 pulled Claude Code's 51 MB of JavaScript out of its Bun binary and ran it on stock Node 24 with a small shim. It reached the same prompt in 3.6 s. V8's own cost was mostly compiling the 61 MB bundle once.
- **What a JS program needs from an OS is small and well known.** Tracing Claude Code's boot found about 2,000 fs calls (about 1,400 of them synchronous), 22 process spawns (two synchronous), a few hundred process and tty calls, and a dozen TLS connections. That's Node's API surface, and Node's API is a thin layer over POSIX that maps onto h9's Linux syscalls almost one for one.
- **The Linux personality already serves those syscalls** ([linux-personality](0018-linux-personality.md)): files, pipes, exec, wait, signals, the tty, and the Linux view of the namespace. Today a syscall arrives as a trap from a vCPU. Nothing in the handlers depends on that.
- **Prior art.** BrowserPod (Leaning Technologies) runs a modified Node in the browser: JavaScript runs on the browser engine, native code is compiled to wasm with Cheerp, and a wasm kernel serves Linux syscalls, with a Worker per process. WebContainers (StackBlitz) does much the same with its own kernel. Both are proprietary, and both need cross-origin isolation. Wanix runs JS tasks in Workers that hold a 9P handle, but with no Node API. None of them shares a kernel with real Linux and 9front binaries, as h9 would.
- **The browser host avoids `SharedArrayBuffer` today** ([browser-host](0012-browser-host.md)): one Worker, coroutines on JSPI, and no COOP or COEP. That's a feature worth keeping for pages that embed h9.

Non-goals:

- **Native hosts.** The h9 CLI has no JS engine. There, `node` stays a Linux binary under the Linux personality, as today. Under `h9-node` (the web build on Node) the runtime works the same, on Node's V8 in a `worker_thread`, which is how it's tested.
- **All of Node.** `h9node` covers what real programs call, measured, and grows by measurement. Native addons (`.node` files) can't load, and `vm` contexts, `inspector`, `cluster`, and the `node:sqlite`-style built-ins are out.
- **Bun and Deno.** A `Bun` global over the same runtime is a later layer. This proposal is Node's API.

## Proposal

### Shape

```
page                     h9 Worker                          JS Worker (one per JS process)
  terminal  <-------->   h9.wasm: kernel, Linux table   <-> h9node: node:* modules, module loader
                         ha64/h86 processes (git, sh)       the program, on the browser's V8
                                ^                                 |
                                +---- syscall channel ------------+
```

A JS process is a `Proc` whose code doesn't run on a vCPU. Its syscalls arrive over a channel from its Worker, and the Linux table serves them as if they came from a trap. It has the Linux personality's view: `/` is the Linux root, with `/9`, `/tmp`, and `/mnt/term` as for any Linux process.

### Starting one

exec picks the personality by the binary, as it does today. A new magic, `#!h9 js` in the first line of a file, means "run the rest of this file's arguments in a JS process":

- `/usr/bin/node` in the web host's Linux view is a two-line file, `#!h9 js node`, bound there by the web host over whatever the root has. A root with a real Node ELF still has it, but the web host's bind wins in the browser. It's at `#λ/usr/bin/node` for anyone who wants the emulated one.
- `#!/usr/bin/env node` scripts resolve through `PATH` to that file, then to a JS process, with the script and its arguments as argv. Without the bind, they run whatever `node` the root has.
- The JS host starts a Worker, loads `h9node`, and hands it argv, the environment, and the process's channel. `process.execPath` is `/usr/bin/node`, so a program that spawns `process.execPath` gets another JS process.

On a native host `#!h9 js` is `ENOEXEC`, so a root that relies on it fails loudly there and not silently.

### The syscall channel

Every `h9node` call becomes a Linux syscall: a number and six arguments, plus the buffers that pointers in them name. The JS Worker has no access to h9's memory, so a request carries its buffers by value, and the reply carries the buffers the kernel fills. In h9, a kernel coroutine per JS process, `jsproc`, takes requests, copies buffers into a scratch area in its own memory, and calls `linux.dispatch` with the arguments rewritten to point there. Blocking is a coroutine park, as for any process, so a JS process waiting on a pipe costs nothing.

Calls are synchronous or asynchronous, by Node's API:

- **Asynchronous** (`fs.promises`, callbacks, streams, `spawn`, and sockets) are `postMessage` requests with an id. Replies arrive as messages, so the Worker's event loop keeps running. Many can be in flight at once; `jsproc` runs each on its own coroutine.
- **Synchronous** (`*Sync`, `spawnSync`, `execSync`, and `process.stdin` reads in a few CLIs) have to block the Worker's JS thread:
  - **Cross-origin isolated pages:** a `SharedArrayBuffer` per JS process, a request slot, and `Atomics.wait` in the JS Worker, with `Atomics.notify` from h9's. A round trip is tens of microseconds.
  - **Pages that aren't:** a synchronous `XMLHttpRequest` to a URL that h9's service worker answers by messaging h9's Worker, as JupyterLite does for `input()`. It's about a millisecond a call, but it needs no headers, so h9 stays embeddable. `createMachine` registers the service worker if the page lets it, and a page that allows neither gets `ENOSYS` for synchronous calls.

  `jsproc` serves a synchronous request like any other. Only the JS side blocks, never h9's Worker.

### Signals and exit

- **Notes and signals** become `process` events. The Linux personality already turns notes into signals. For a JS process, delivery is a message, and `h9node` emits `SIGINT`, `SIGTERM`, `SIGWINCH`, and the rest. With no listener, the default action happens, as in Node: h9 ends the process.
- **`SIGKILL`, and any default fatal action,** terminate the Worker from the JS host, which then completes the exit in the kernel. A process blocked in `Atomics.wait` dies the same way.
- **`process.exit(n)`** is `exit_group(n)`, and the Worker ends when its event loop is empty, exactly when Node's would: `h9node` counts what keeps it alive (handles, timers, and pending calls). Uncaught exceptions print as Node prints them, then exit 1.

### `h9node`

Node's built-in modules come in three kinds:

| Kind | Modules | Source |
| --- | --- | --- |
| Pure JS | `buffer`, `events`, `path`, `url`, `querystring`, `util`, `string_decoder`, `stream` and `stream/*`, `readline`, `assert`, `timers`, `punycode`, and `diagnostics_channel` | Node's own `lib/` (MIT), with its `internalBinding` calls replaced |
| Over syscalls | `fs`, `fs/promises`, `child_process`, `process`, `tty`, `os`, `net` (sockets via `/net`), `dns` (through `/net`, where the web host's proxy resolves names), `module`, and `worker_threads` (a JS process sharing the parent's channel, later) | new, in `src/web/h9node/` |
| Over browser APIs | `crypto` (hashes, HMAC, and KDFs in JS; `randomBytes`, `randomUUID`, and `webcrypto` native; keys and signatures over WebCrypto), `zlib` (fflate, with zstd and brotli in wasm), `perf_hooks`, `fetch`, `WebSocket`, `URL`, `TextEncoder`, `structuredClone`, and `AbortController` | the Worker's own, and small libraries |

Approximated: `async_hooks.AsyncLocalStorage` (propagated through h9node's own callbacks and patched promise jobs, until the TC39 AsyncContext ships), and `vm` (`runInThisContext`, `Script`, and `isContext`; no new contexts).

The process-facing details:

- **`fs`** maps call for call: `openat`, `read`, `pread64`, `getdents64`, `statx`, `renameat2`, and the rest. `fs.watch` is polling at first. Stats come from `statx`, so `ino`, `mode`, and times are what busybox sees.
- **`child_process`** is `clone(SIGCHLD)` plus `execve` done in one request, `spawn`, because a JS process can't fork. Its stdio are pipes or inherited fds, just as Node sets them up. So the child can be any personality: a 9front `rc`, a Linux `git`, or another `node`.
- **`process.stdin`, `stdout`, and `stderr`** are fds 0, 1, and 2. `isTTY`, `setRawMode`, and `columns` and `rows` come from the Linux personality's tty ioctls on the console.
- **Modules** load the way Node loads them, over `fs`: CommonJS with Node's resolution, `package.json` `exports`, and `.json`. ES modules are rewritten into a registry form with live bindings (`es-module-lexer` finds the imports), so `require(esm)`, cycles, and top-level await behave as in Node 22 and later. Sources are read through h9 and compiled with `new Function`. For V8 to cache compiled code across page loads, modules under `/usr/lib/node_modules` and the program's own tree can instead be imported from service-worker URLs, which Chromium code-caches like any script.

### The network

The JS Worker gets **no direct network**. It starts with a Content-Security-Policy of `connect-src 'none'; worker-src 'none'`, and `h9node` removes `fetch`, `WebSocket`, `XMLHttpRequest`, `importScripts`, and `EventSource` from the global object before any program code runs. Everything goes through h9:

- **`net.Socket`, `tls`, `http`, and `https`** go over `/net`, which in the web host is `/net/ws`, a TCP-over-WebSocket proxy ([websocket-9p](0021-websocket-9p.md)). TLS is done in JS (as Node does in OpenSSL). It's slow to set up, but byte-exact, and it needs no CORS.
- **`fetch`** is `h9node`'s, a request to h9's Worker, which checks the machine's net policy and then uses the browser's `fetch`. That's fast and handles TLS in the browser, but CORS applies. A program that needs a host without CORS can set `H9NODE_FETCH=socket` to send `fetch` over `/net` instead.

### Limits

- **Memory.** A Worker's heap isn't part of `--memory`. `h9node` sets the V8 heap limit where the browser allows it, and reports `--memory` as `os.totalmem()`. The docs list it as unenforced for JS processes, as the browser host already does for parts of `--net`.
- **CPU.** Each JS Worker is a real browser thread, outside h9's scheduler, so `--cpus` doesn't limit it. That's the point (the program runs in parallel with h9's emulated processes), and it's stated in the docs.

## Rationale

**A process in h9, not a JS sandbox beside it.** A Node polyfill with its own in-memory fs (the browserify approach) would run scripts, but not `git` on the files they write, nor `npm` scripts that shell out. Sharing h9's kernel is what makes it a machine, not a toy, and the Linux table is already the right ABI.

**Linux syscalls, not 9P, as the channel.** A JS process could hold a 9P connection (Wanix's JS tasks do), and `h9node` could map `fs` onto `walk`, `open`, and `read`. But Node's model is POSIX's: fds that survive exec, pipes, `waitpid`, signals, ttys, and cwd. The Linux personality already implements all of that once. Over 9P, `h9node` would reimplement it, and differ from busybox in small ways.

**V8 in the browser, not V8 or Node in wasm.** Compiling Node or a JS engine to wasm (as BrowserPod compiles Node's C++) gives exact Node, but it's a huge build to own, and JIT-less or slow. The browser's V8 is fast, already there, and is what pages want. Node's JS layer runs on it nearly unchanged.

**Workers, not one Worker.** Running JS processes inside h9's Worker would need no channel, but a synchronous call couldn't block without blocking the kernel, and a busy script would freeze every other process. One Worker per process gives parallelism and isolation, at the cost of the channel.

**The service-worker path for synchronous calls.** Requiring `SharedArrayBuffer` would be simpler, but would make every embedding page set COOP and COEP, which breaks embedding third-party content. The browser host avoided that on purpose. The service-worker path is slower but works everywhere service workers do, and pages that can opt into isolation get the fast path.

**`#!h9 js`, not a new binary format.** A text magic keeps it greppable and lets the root decide which names mean the V8 runtime. A device file (`#J/node`) was the alternative, but the shebang needs no new device, and it follows exec's existing `#!` handling.

## Compatibility

- **CLI and `Machine.Options`:** none. The web host binds `/usr/bin/node` in its Linux view. A `createMachine` option, `node: false`, turns that off, so the root's own `node`, if any, runs emulated.
- **Root trees:** none required. A Linux root doesn't need Node installed. npm, if wanted, is a pure-JS package that runs on `h9node`.
- **Native hosts:** `#!h9 js` files are `ENOEXEC`. Nothing else changes.
- **`third_party/`:** Node's `lib/` (MIT), es-module-lexer (MIT, wasm), fflate (MIT), and @noble/hashes (MIT), vendored with pinned hashes.

## Security

- **What's new is the JS Worker,** which runs guest code with the browser's full JS API unless it's removed. The CSP header on the Worker's script is the enforcement: `connect-src 'none'` blocks `fetch`, WebSocket, and EventSource even if a program restores them, and `worker-src 'none'` stops it from starting Workers of its own. Removing the globals is only defense in depth.
- **Every file, process, and network operation** is a syscall to h9, so the machine's policy (`--net`, `--net-allow`, read-only roots, and masks) covers it exactly as for a Linux process. `h9node`'s `fetch` is checked against `--net-allow` by host name, which the browser host already documents as name-only.
- **The service worker** answers only requests from the machine's own JS Workers, matched by a per-process token in the URL, so another page or frame can't make syscalls.
- **Memory and CPU** aren't bounded by `--memory` and `--cpus` (see Limits). A runaway script can take a browser thread and its heap, as any page script can. The JS host's kill ends it.

## Done when

Under `h9-node` and in Chromium (`zig build web-test`), with the cases tagged `[js-runtime]`:

- `test "node -e prints and exits 0 [js-runtime]"`
- `test "node exit code and uncaught exception exit 1 [js-runtime]"`
- `test "#!/usr/bin/env node script runs with argv [js-runtime]"`
- `test "writeFileSync is visible to busybox cat [js-runtime]"`
- `test "spawnSync busybox echo returns stdout and status [js-runtime]"`
- `test "node | busybox wc -l pipeline [js-runtime]"`
- `test "child_process.spawn of node gets another JS process [js-runtime]"`
- `test "SIGINT with and without a listener [js-runtime]"`
- `test "SIGKILL ends a process blocked in readFileSync [js-runtime]"`
- `test "setRawMode and SIGWINCH on the console [js-runtime]"`
- `test "require, ESM import, require(esm), and a cycle [js-runtime]"`
- `test "fetch is denied by --net disable [js-runtime]"`
- `test "global fetch removed and CSP blocks a restored one [js-runtime]"`
- `test "sync calls work without cross-origin isolation [js-runtime]"`

And a demo: in Chromium, `npm install` of a small pure-JS package over `/net/ws`, then running its CLI. Node's own test suite (`test/parallel`) for `fs`, `child_process`, `path`, `stream`, and `buffer` runs as a tracked pass rate, not a gate.

## Implementation

1. `h9node`'s pure-JS modules from Node's `lib/`, with a fake `internalBinding`, running `node -e` with no OS calls at all, under `h9-node`.
2. The channel: the `jsproc` coroutine in h9, `postMessage` for async calls, and the `SharedArrayBuffer` path for sync calls. First `fs`, `process`, and stdio.
3. `#!h9 js` in exec, the JS host's Worker start, exit, and the `/usr/bin/node` bind.
4. `child_process`, pipes, signals, and the tty.
5. The module loader (CommonJS, then ESM through the registry form).
6. The service-worker path for synchronous calls, and `createMachine` registering it.
7. The network: the Worker's CSP, `h9node`'s `fetch` under the policy, and `net` and `tls` over `/net`.
8. `crypto`, `zlib`, `dns`, and `os`, and then measured gaps from running real programs (npm, a TypeScript compiler, and Claude Code).

## Open issues

- **Code caching for `new Function` sources.** V8 caches only scripts loaded by URL. The service-worker route gets caching, but makes module loading depend on the service worker. Is the cost of compiling large programs on every load acceptable without it?
- **`worker_threads`.** Is a second Worker with a `MessagePort` to the first, sharing the process's channel, enough? Threads that share memory through `SharedArrayBuffer` need cross-origin isolation either way.
- **JS TLS.** Which library (forge, or rustls compiled to wasm)? Or is `fetch` through the browser enough for most programs, with raw TLS only on request?
- **Firefox and Safari.** Both have Workers, service workers, and `Atomics.wait` in Workers. Is synchronous XHR from a Worker to a service worker reliable in both?
- **The Bun layer.** A `Bun` global over `h9node` would run Bun programs and their standalone builds. Should it be in this proposal's scope, or its own?
