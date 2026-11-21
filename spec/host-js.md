# The browser host

This describes, as built, h9 on wasm32-wasi: the browser host, and the same build under Node. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Browser host (`web`)](#browser-host-web)
  - [The 386 CPU on the web](#the-386-cpu-on-the-web)
  - [Hosts](#hosts)

## Browser host (`web`)

`zig build web` builds h9 for wasm32-wasi into `zig-out/web/` ([browser-host](../design/epoch-0/browser-host.md)). The kernel, the machine, and the CLI are the same code; what differs is underneath them. Native hosts are unchanged.

| Piece | Web host |
| --- | --- |
| Threads | Coroutines on JavaScript Promise Integration (`src/web/coro.c`): each kernel process, and each of h9's own threads (`web.Thread`), has its own shadow stack and its own suspendable wasm stack, started through the exported, `promising`-wrapped `h9_coro_entry`. Blocking parks through a `Suspending` import whose Promise the JS host resolves, so the event loop is the scheduler. Every Suspending import (park, yield, sleep, the console read, and the signal wait) saves and restores what's per thread natively: `__stack_pointer` (`src/web/stack.S`), `errno`, h9's Zig threadlocals, and drawterm's `up`. |
| OS layer | `src/kern/os-wasm.c` instead of `posix.c`: `procsleep` and `procwakeup` park and unpark, `osyield` yields through a `MessageChannel`, timers park with a timeout, and `devip-wasm.c` stubs the sockets. |
| Stacks | wasm has no guard pages, so each stack has a canary at its low end, and every park and coroutine exit also checks the stack pointer against it; either failing panics the machine with the coroutine's name. Kernel processes and h9's own coroutines get 320 KiB: the integration suite's deepest use at a park (149 KiB, in a guest process's syscall path, Debug build), doubled and rounded up. Stacks go on a free list when their coroutine ends. |
| `std.Io` | `src/web/io.zig`: std's single-threaded implementation over WASI, with futex waits and sleeps that park. 64-bit atomics become plain values (`web.Atomic`), since wasm32 has no 64-bit atomic RMW. |
| Files | WASI. Under Node, `h9-node` preopens `/`, so roots and `--cwd` are real host directories, resolved with readlink one component at a time since WASI has no realpath. In the browser, `src/web/wasi-mem.js` serves a read-only tree from `root.h9a`, which `tools/webroot.zig` packs from the 386 root and `src/web/root.list`. WASI has no permission bits, so `#U` (devfs, wrapped in `src/kern/devtab.c`) gives files and directories `rwxrwxr-x`; the policy, not the mode, decides access. |
| Console | `src/web/cli.zig`: stdin, interrupt, hangup, and raw mode are imports the JS host serves, from Node's process or from the page's messages. |
| Policy | `#C` and `#I` are always masked. The network is WebSockets only: `--net=outbound` (the default) and `enable` bind `#ℏ` alone at `/net`, and `disable` masks it. |
| WebSockets | `hstream.zig`'s web branch calls `h9-web.js`'s `h9_ws_*` imports, over the runtime's `WebSocket` ([websocket-9p](../design/epoch-0/websocket-9p.md)): `ws_open` and `ws_send` return at once, `ws_opened` and `ws_recv` are Suspending, and a stream's reader is a coroutine parked in `ws_recv`, which hands over as many queued binary messages as fit. The browser does the handshake, TLS, proxies, and pongs, so `--root-header`, `--root-ca`, and `header` in `ctl` are errors, there's no keepalive, and a failed connection says only "connection failed". `--net-allow` checks a connect's name or literal address but can't check what a name resolves to, which the plan lists as a caveat. |

### The 386 CPU on the web

Web builds run 386 binaries on h9's own CPU, h86 (`src/vmm/h86.zig`, through `src/vmm/hcpu.zig`), the only backend there; `--backend v86`, the name of the v86 backend it replaced, is an alias of `emu`. Guest memory is an arena grown with `memory.grow` in h9's own linear memory (`src/vmm/arena.zig`), 256 MiB by default.

T0 interprets; T1 (`src/jit/wasm_t1.zig`) counts entries to blocks and, once a vCPU has retired 2M instructions, lifts hot ones, batches them into a module (`src/jit/emit/wasm.zig`, a function per region, with chain cells and a jump-cache lookup for indirect branches), and has `h9-web.js` compile it asynchronously into table slots of h9's own function table; T0 runs until the batch is installed. `CodePages`' invalidation drops a page's regions and their slots.

Preemption is a budget: each slice runs 64K instructions at a time, and `run` yields to the event loop once 2 ms have passed since the last yield, returning `.interrupted`; a Linux `sched_yield` is the kernel's `sleep(0)`, a coroutine switch here.

### Hosts

`h9-node` runs the CLI under Node 24 or later, with the same flags as `h9`; it's how the integration suite tests the web host.

In a page, `createMachine({ root, memory, policy, terminal, gfx })` from `h9-web.js` starts one machine in its own Worker (`src/web/worker.js`) and `machine.run(argv)` resolves to the exit status. `gfx` gives it a canvas ([Graphics](machine.md#graphics---gfx)).

`root` is a root archive's URL, or a `ws://` or `wss://` URL of a 9P server, under which WASI sees an empty tree; the page edits and echoes lines in cooked mode, passes keys in raw mode, and sends the interrupt key as `Machine.Signals.interrupt`.

The demo page (`index.html`) runs an interactive rc, over `?root=` when given, or with `?rio`, rio and acme on a canvas.
