---
issue: 12
slug: browser-host
title: A browser host on wasm, with v86
status: implemented
created: 2026-11-04
authors: [progrium]
depends: [go-compat, i386]
areas: [vmm, kern, build, tests]
branch: [main]
---

# Proposal: a browser host on wasm, with v86

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 builds for wasm32 and runs in a Web Worker, with no VM image, boot, or guest kernel, as on every other host. drawterm's kernel runs unchanged above a new OS layer whose kernel processes are coroutines, built on JavaScript Promise Integration (JSPI). Guest code runs on a new vmm backend, v86, which emulates a 32-bit x86 CPU and compiles hot code to wasm, so the browser host runs 9front's 386 binaries ([i386](i386.md)). The same build runs under Node, which is how the integration suite tests it.

## Background

Today h9 needs a host OS: threads for kernel processes, POSIX or Win32 for devfs, and a hypervisor or Unicorn for guest code. None of those exist in a browser.

What does exist:

- **wasm, in a Worker.** It can run for as long as it needs and block only through the event loop.
- **JSPI.** A wasm call into JavaScript can return a Promise, and the wasm stack suspends until the Promise settles. JSPI is phase 4. As of mid-2026 it ships in Chrome and Edge 137 and later and in Safari 27 beta, and in Firefox Nightly behind a pref, with default-on intended for Firefox 153.
- **v86.** A BSD-2-licensed x86 PC emulator whose CPU core is Rust compiled to wasm. Its JIT turns hot guest code into wasm modules. It emulates 32-bit x86 with x87, SSE2, FXSAVE, and PAE paging. Its run loop (`main_loop`) runs guest code in slices of about 1 ms and returns early when the CPU halts. Its registers sit at fixed addresses in its linear memory.
- **9front's 386 port,** still released ([i386](i386.md)).

drawterm's kernel reaches its OS through a small layer, `kern/posix.c` or `kern/win32.c`:

- `osproc` starts a kernel process on a thread
- `procsleep` and `procwakeup` block and wake it
- `_getproc` and `_setproc` hold `up`
- `osyield`, `osmsleep`, `seconds`, `ticks`, and `randomread` cover time and randomness
- `oscmd` runs host commands

Everything else in kern (chans, devmnt, qio, `sleep`/`wakeup`, qlocks) is built on that layer. Only three other pieces of state are per thread: `up`, h9's `fs_plan` (a `threadlocal` in `src/kern.zig`) and libc's `errno`.

## Proposal

### Shape

```
main thread (page)                 Worker
  terminal UI  ── postMessage ──>  h9-web.js      JS host: coroutines, console, WASI shim, v86 glue
                                   h9.wasm        Zig + drawterm C, wasm32-wasi
                                   v86.wasm       v86's CPU core, sharing h9.wasm's memory
```

One Worker holds one machine. Inside it everything is single-threaded. Concurrency comes from coroutines: one per kernel process, plus a few for h9's own tasks, such as the console reader.

### Coroutines on JSPI

- **Entry.** `h9.wasm` exports `h9_coro_entry(fn, arg)`. The JS host wraps it once with `WebAssembly.promising`. Starting a coroutine is calling the wrapped function without awaiting it, which gives the coroutine its own suspendable wasm stack.
- **Parking.** All blocking goes through one import, `h9_park(token)`, wrapped with `WebAssembly.Suspending`. It returns a Promise that `h9_unpark(token)` resolves. A coroutine that parks gives the event loop back, and the event loop is the scheduler.
- **The OS layer** is `src/kern/os-wasm.c`, built instead of drawterm's `kern/posix.c`. The vendored tree stays unmodified.

  | drawterm | os-wasm.c |
  | --- | --- |
  | `osproc(p)` | Allocates a stack and starts a coroutine running `p->fn` |
  | `procsleep`, `procwakeup` | `h9_park`, `h9_unpark` on the Proc's token |
  | `_getproc`, `_setproc` | A global `up`, swapped on every switch |
  | `osyield` | Parks on a Promise resolved through a `MessageChannel`, which isn't clamped like `setTimeout` |
  | `osmsleep` | Parks on a timer |
  | `seconds`, `ticks` | `Date.now()`, `performance.now()` |
  | [go-compat](go-compat.md)'s clock leaf | Wall nanoseconds from `performance.timeOrigin + performance.now()`, and monotonic nanoseconds from `performance.now()`, offset as go-compat describes. Browsers coarsen `performance.now()` to about 100 µs on pages that aren't cross-origin isolated, so that's the web host's `/dev/bintime` resolution there. `Tos.cyclefreq` keeps go-compat's value. |
  | `randomread` | `crypto.getRandomValues` |
  | `oscmd` | Not built: `#C` is unavailable |
  | `tas` | Unchanged. With one thread, a contended spin lock is a bug, so `lock` asserts it's free. |

- **Per-coroutine state.** wasm globals aren't per stack, so every switch saves and restores:
  - `__stack_pointer`, the C and Zig shadow stack. Each coroutine gets its own stack region. The pointer is read and set from `src/web/stack.S`, since there's no builtin for it.
  - drawterm's `up`.
  - h9's `fs_plan`.
  - libc's `errno`. devfs reads it after host calls, and another coroutine may have run in between.

  `h9_park` does the save and restore, so no other code needs to know.
- **Coroutine stacks.**
  - **No guard pages.** wasm has none, so a coroutine that overflows its shadow stack silently corrupts whatever is below it. Each stack has a canary word at its low end. `h9_park` and coroutine exit check it, and a broken canary panics the machine with the Proc's name rather than corrupting it further.
  - **Size.** The default is measured, not guessed. In the Node spike, stacks are filled with a pattern, and the integration suite's deepest use, doubled, becomes the default.
  - **Reuse.** wasm memory never shrinks, so stacks go on a free list when their kernel process exits and are reused before any new one is allocated.
- **No JS frame under a park.** JSPI traps if a suspension crosses a JavaScript frame. Parks happen only in kernel code that wasm reached from `h9_coro_entry`. JS imports that wasm calls, such as v86's `microtick` and the WASI shim, return without parking. Imports that do park are wrapped as `Suspending`.
- **Errors.** drawterm's `waserror`/`error` is setjmp and longjmp. In wasm that's the exception-handling proposal:
  - C is compiled with `-mexception-handling -mllvm -wasm-enable-sjlj`.
  - wasi-libc's `setjmp/wasm32/rt.c` is linked in.
  - The link step itself doesn't take `-mexception-handling`.

  With Zig 0.16 this builds and runs under Node 22. A longjmp unwinds only within its own coroutine's stack, which is where seam rule 1 already keeps it.

### h9's own threads

h9 uses `std.Thread` in four places:

- the kernel's boot thread (`kern.zig`)
- the console reader (`consin.zig`)
- the vCPU pool (`cpupool.zig`)
- the CLI's signal watcher (`hostsig.zig`)

On the web host the boot thread and the console reader run as coroutines, through `h9_kern_spawn`'s path or `std.Io.concurrent`. The pool is never needed, since v86's vCPUs are cheap contexts and `maxVcpus` is large. The signal watcher isn't built.

h9 also passes a `std.Io` everywhere. The web host provides `src/web/io.zig`, a `std.Io` whose futex wait parks, whose `concurrent` starts a coroutine, and whose clock is `performance.now()`. Operations the host doesn't have fail with an error.

These are internal changes: on native hosts everything stays on threads as now.

### Filesystem: WASI

`h9.wasm` targets wasm32-wasi, so drawterm's devfs-posix builds as it is against wasi-libc. The root tree is a WASI preopened directory, and the sandbox policy's `h9_fs_check` hooks keep working.

- **Node** provides WASI with real host directories, so the integration suite runs against the same root tree on disk as native runs.
- **In the browser,** the JS host implements the WASI calls devfs uses over an in-memory tree. The tree is loaded from a root archive that `zig build web` makes from the root tree. The full 386 root is too large to load up front, so the archive holds only what the demo and the `[baseline]` cases use: rc and its scripts, the commands they run, and the files those read. A list in the build names them.

WASI imports can be `Suspending` like any other, so a later backing can be asynchronous: files fetched on demand, OPFS for persistence, or a Wanix filesystem. The kernel doesn't change for any of these.

### Console

The machine's console (`#y`) is fed by the page. `Machine.Stdio` is implemented by the JS host:

- writes post messages to the main thread
- reads park until a message brings input
- `rawon` and `rawoff` tell the page's terminal to switch modes

The page sends an interrupt key as `Machine.Signals.interrupt`, which posts `interrupt` to the foreground note group, as Ctrl-C does on a TTY.

### The v86 backend

`src/vmm/v86.zig` implements Backend, AddressSpace, and Vcpu over one v86 CPU per machine.

**One memory.** `h9.wasm` and `v86.wasm` share one linear memory, so `AddressSpace.translate` can return a host slice as the contract requires, and the kernel reads syscall arguments in place.

- `v86.wasm` defines and exports the memory and owns its low part: its fixed register block, its data, and its stack. The prebuilt release (0.5.473) is linked with `--global-base=4096` and `--import-table`. Its data ends near 36 KiB, its stack starts at about 9.1 MiB, and the memory has 146 initial pages and no maximum.
- `h9.wasm` is linked with `--import-memory` against that export, with `--global-base` at a fixed 16 MiB so its data, stack, and heap sit above v86's region with room to spare.
- Both modules' heaps grow with `memory.grow`, which hands each grow to the module that asked. Rust's allocator only uses pages it grew itself. wasi-libc's malloc instead claims everything from `__heap_base` to the memory's size on first use. So instantiation runs in a fixed order: instantiate v86, grow the memory past h9's stack, instantiate h9, and make its first allocation, and only then call v86's `allocate_memory`. After that, grows from the two heaps can interleave.
- v86's guest RAM is one allocation from v86 (`allocate_memory`), sized by `--memory`. It's the guest-physical region every backend has, and `allocPages` hands out pages from it.
- The register block's offsets (`instruction_pointer`, `in_hlt`, the general registers, `cr`, `cpl`) aren't a stable ABI and can move between v86 releases. `scripts/pins.sh` records them with the release hash, and a test checks them against the pinned `v86.wasm`.

**Guest kernel and shim.** `src/arch/i386/shim.S` is loaded at a fixed guest-physical address and started in real mode, as a boot sector would be. It:

1. sets up a GDT (kernel and user code and data, a TSS), an IDT, and paging
2. enables FXSR
3. halts

The GDT, IDT, and TSS are shared by every vCPU, since only one runs at a time. Then:

- **Trap entry.** On any trap or `INT $64`, the shim's vector pushes a frame on the kernel stack and halts. The frame is exactly the 386 Ureg: PUSHAL order, the segment registers, trap and error code, then the hardware's iret frame. A page fault also stores CR2.
- **Exit.** The halt ends v86's run loop, and the backend reads the Ureg straight from the kernel stack page. This differs from the `OUT` doorbell other x86 backends use. v86 hands port I/O to a JS import and keeps running, while a halt at ring 0 with interrupts off sets `in_hlt`, calls the `cpu_event_halt` import once, and ends `main_loop`. That import returns at once and never parks.
- **Resume.** The backend writes the Ureg into the frame, points ESP at it and EIP at the shim's restore path (pop the registers, `iret`), and calls `main_loop`. v86 exports nothing that clears a halt, and with interrupts off `main_loop` treats a halted CPU as dead and returns at once. So the backend clears `in_hlt` by writing it in v86's register block first.

**Vcpus are contexts.** A Vcpu is a Ureg, an FXSAVE image, and a page-directory address. `run` installs them, with `fxrstor` and `fxsave` in the shim only when the context differs from the one last run. It sets CR3, which flushes v86's TLB, then calls `main_loop` until a halt or the end of the slice.

**Preemption.** When a slice ends without a halt, `run` parks through `osyield` and then returns `.interrupted`. `Machine` already treats that exit as "deliver notes, then run again". A spinning guest gets about 1 ms before every other coroutine and the page's messages get a turn. The vmm interface doesn't change. `kick`, from another coroutine, sets a flag that `run` checks between slices.

**Address spaces.**
- Each address space is a two-level 386 page directory in guest-physical memory, as 9front's pc kernel uses. Text is mapped read-only; as on 9front 386, nothing is marked non-executable.
- `map` and `unmap` write page-table entries.
- `unmap` on the address space that's running also clears v86's TLB through its `clear_tlb` export.

**The JIT and host writes.** v86 notices guest writes to pages it has compiled, but h9's writes go around it. The loader copying text and syscalls filling buffers write the memory directly. So the backend calls v86's `jit_dirty_page` (or `jit_dirty_cache` for a range) for a page when it's freed and when it's mapped executable. Recycled pages then never run stale compiled code.

**Faults.** A page fault exits as `.fault` with CR2 and the access type from the error code. Other vectors fault with the vector as the syndrome. `Ureg.trap` holds what 9front's kernel puts there.

**The glue.** v86's own JavaScript (`cpu.js`, `starter.js`) isn't used. `h9-web.js` provides the imports `v86.wasm` needs:
- `microtick`
- `run_hardware_timers`, which returns at once since there are no devices
- `codegen_finalize` and `jit_clear_func` for the JIT: compile the generated module, which a Worker may do synchronously, and set it in the shared function table
- `cpu_event_halt` and `stop_idling`, which return at once, since the backend learns of a halt from `main_loop` returning
- `get_rand_int`, from `crypto.getRandomValues`
- `console_log_from_wasm`, to the Worker's console
- stubs for the port and MMIO imports (`io_port_*`, `mmap_read*`, `mmap_write8` through `mmap_write128`), which a guest at ring 3 can't reach

**Selection.** `vmm.Kind` and `BackendKind` gain `v86`. It's the only backend in web builds, and `auto` picks it. It runs i386 only; anything else fails with `WrongArch`.

### Build and API

- `zig build web` produces `zig-out/web/`: `h9.wasm`, `h9-web.js`, `v86.wasm` with its BSD-2 notice, a root archive, and a demo page.
- `v86.wasm` is a pinned release build, fetched by `scripts/fetch.sh` and checked against a hash in `scripts/pins.sh`, as Unicorn's wheels are. `-Dv86=source` builds it from the pinned source with cargo instead.
- The CLI's `cli.zig` and `main.zig` build into `h9.wasm` too, so Node can run `h9` with the same flags (`zig-out/web/h9-node`).
- In the page, `h9-web.js` exports `createMachine({ root, memory, policy, terminal })` and `machine.run(argv)`. Both mirror `Machine.init` and `run` and return the same exit status.

## Rationale

**Why v86 rather than waiting for the interpreter.** v86 is mature and already compiles x86 to wasm, which is the fastest way to run guest code in a browser. It needs no new CPU work, only a backend, a shim, and glue. The [zig-interpreter](zig-interpreter.md) is complementary: once it exists it can run arm64 binaries on the web host from the same root tree, and v86 stays for x86. Neither proposal depends on the other.

**Why 386.** v86 has no long mode, so amd64 isn't possible on it. 9front still builds and releases 386, and its compilers are the same family as 7c and 6c.

**Why JSPI.** It keeps drawterm's blocking code as it is. Each kernel process blocks on its own stack, as it does on a thread.

- **Asyncify** instruments every function that could be on the stack during a suspend, which here is most of the kernel. It grows code size and slows every call. It also doesn't support the exception-handling proposal, which the kernel's setjmp and longjmp need here, so it isn't even a drop-in fallback for browsers without JSPI.
- **wasm threads with SharedArrayBuffer** map more directly onto drawterm's threads. But they need the page to be cross-origin isolated, which limits where h9 can be embedded. They need wasi-threads support in Zig and libc. And they gain little, since one v86 CPU runs one context at a time.
- **An event-driven rewrite of the kernel** would leave drawterm behind for good.

**Why share one memory.** The vmm contract hands the kernel host slices of guest memory. With two memories, every syscall argument, read, and write would be a copy through JavaScript.

**Why WASI for files.** devfs-posix, and the sandbox hooks in it, work unchanged. Node's WASI gives the test suite real directories, and the browser only needs a WASI shim, for which there are existing implementations to start from. A dedicated device would duplicate devfs.

**Alternatives rejected.**
- **Booting 9front itself in v86.** That's already possible with v86 alone, and it's what h9 exists to avoid.
- **Wanix as the kernel.** h9 would lose drawterm's semantics and its own process model. Wanix fits better as something the root or namespace is backed by.
- **Unicorn compiled to wasm.** It's GPL, interprets in wasm without a JIT to wasm, and is a large build.

## Compatibility

- **SPEC.md's goals.** "Run native code only" and the non-goal of translating across architectures for users assume a CPU to run natively on. A browser has none. SPEC.md would say that the web host runs 386 binaries on v86, and that this is its only mode.
- **vmm.** `Kind` and `BackendKind` gain `v86`. `--backend v86` is accepted everywhere and fails with `BackendNotBuilt` outside web builds. The [i386](i386.md) proposal changes `Extra`; this one changes nothing else in the interface.
- **Machine and CLI.** `Machine.Options` is unchanged. In web builds the policy always masks `#C`, which doesn't exist, and `#I`, since there's no socket API. `--net` other than `disable` is listed as unenforced, and `--strict` refuses it. `--host-cmd` is a usage error.
- **Build and releases.** A new step, `zig build web`, and a new release archive, `h9-web-<version>.tar.gz`. Native builds are unchanged. h9 stays MIT. The archive carries v86's BSD-2 notice and the root archive's 9front licence.
- **Browsers.** JSPI is required. `h9-web.js` checks for `WebAssembly.Suspending` before it starts the Worker, and `createMachine` rejects with "this browser lacks JavaScript Promise Integration" if it's missing. There's no fallback build (Rationale).
- **Root tree.** The [i386](i386.md) root. The browser gets a trimmed archive of it.
- **Network.** None from this proposal: `#I` is masked. [websocket-9p](websocket-9p.md) gives the web host a 9P root over a WebSocket and the guest's `/net/ws`.
- **Out of scope.** Graphics, which would be a canvas backend for [gfx](gfx.md) in its own proposal. arm64 on the web host, which is for [zig-interpreter](zig-interpreter.md) or a later proposal to decide; here a page runs one 386 root.
- **`third_party/`.** Unchanged. v86 isn't vendored: the build fetches or builds it from a pin.

## Security

**The boundary.** In a browser the outermost sandbox is the browser's: the Worker reaches nothing beyond what `h9-web.js` gives it. Inside it, the guest is isolated from the kernel by v86's emulation and by the kernel itself, which serves every syscall, as on the emulator backend.

**One memory.** Because guest RAM and h9's heap are one linear memory, a bug in v86 that reaches outside guest RAM could corrupt the kernel. A Unicorn bug can corrupt the native h9 process the same way, but two separate memories would have contained it. That's the cost of in-place syscall arguments.

**Guest reach.** It's only the namespace the policy builds:
- the root archive or a directory the embedder lends through WASI
- the console
- no network
- no host commands

Nothing in the page is reachable except through those imports.

**v86's JIT** generates wasm from guest code. That wasm runs inside the same Worker sandbox with access to the same linear memory, so it adds nothing a v86 interpreter bug wouldn't.

**The embedder** decides what the root and lent directories contain, and whether OPFS persistence is used. The JS API takes the same `Policy` as native embedders.

## Done criteria

- [x] `zig build web` builds `zig-out/web/` from a clean checkout, with `v86.wasm` checked against its pin.
- [x] Under Node with JSPI, `zig build integration -Dweb` passes the `[baseline]` cases on `H9_TEST_BACKENDS=v86` and the 386 root. The exceptions are cases that need a host TTY or POSIX signals, which the web host doesn't have: raw mode, Ctrl-C, SIGTERM, and hangup. Those skip on web builds, by name.
- [x] `tests/backends.zig` passes on v86 under Node for its i386 cases.
- [x] New cases tagged `[browser-host]`:
  - `test "a spinning process doesn't starve a pipeline [browser-host]"`
  - `test "a console read parks and resumes on input [browser-host]"`
  - `test "a note interrupts a parked console read [browser-host]"`
  - `test "errno survives a park [browser-host]"`
  - `test "exec into recycled pages doesn't run stale JIT code [browser-host]"`
  - `test "RFMEM processes see each other's writes [browser-host]"`
  - `test "a coroutine stack overflow panics instead of corrupting [browser-host]"`
- [x] **Demo:** the page from `zig build web` runs an interactive rc in Chrome. `ls /bin | wc -l` prints the count, and the interrupt key stops `cat` and returns to rc. A Playwright test in CI does the same.

## Implementation

1. **Spike in Node.** Get kern building for wasm32-wasi with the sjlj flags. Run one coroutine that parks in `procsleep` and is woken from JS, with the `__stack_pointer`, `up`, and `errno` swap and the stack canary in place. This tests JSPI, the stack switching, and setjmp together before anything else depends on them.
2. **Shared memory spike.** Instantiate the prebuilt `v86.wasm` and `h9.wasm` on v86's memory in the order above, with wasi-libc's malloc and v86's allocator both active, and check that neither heap overlaps the other or guest RAM. Record the register-block offsets in `scripts/pins.sh`.
3. **The OS layer and Io.** `src/kern/os-wasm.c`, `src/web/stack.S`, `src/web/io.zig`, and the four `std.Thread` uses moved behind them.
4. **WASI root under Node.** `h9-node` runs `echo` from a 386 root on a stub backend that only executes syscalls.
5. **The v86 backend.** The shim, contexts, faults, preemption, and JIT dirtying. Then the integration suite under Node, with stack depths measured to set the default stack size.
6. **Browser.** The WASI shim over the root archive, the console over messages, the demo page, and the Playwright test.
7. **Release and docs.** The `h9-web` archive in `scripts/release.sh`, the README, and SPEC.md's host and backend sections. Set `status: implemented`.

## Open issues

- **A full root in the browser.** Beyond the trimmed archive: a manifest of paths, sizes, and hashes, with files fetched on demand through `Suspending` WASI calls and cached in OPFS, or a Wanix filesystem. [websocket-9p](websocket-9p.md) covers a remote 9P root, and a [9P root](9p-roots.md) over a MessagePort to the page is another option. Each would be its own proposal.
- **The memory layout, if the spike fails.** If v86's allocator or a later release doesn't fit the order in "One memory", v86 is built from source with `--import-memory` and a fixed base instead, which puts cargo in the build.

## Updates

- 2026-11-06: [serve](serve.md) makes `--serve` a usage error on the web host, since a page can't listen. Its per-connection path takes any devhstream stream, not a socket, so the machine could be served to its embedder over a `MessagePort`, as `createMachine({ serve: port })`, with the port's messages as the stream's frames, in `h9-web.js` and `hstream.zig`'s web branch. That's a follow-up proposal, not this one's work.
- 2026-11-06: [websocket-9p](websocket-9p.md) is implemented natively, and its step 8 is now this proposal's work: the `h9_ws_*` imports in `h9-web.js`, `hstream.zig`'s web branch, `createMachine`'s URL root, `/net/ws` as the web host's network, and websocket-9p's `[websocket-9p, browser-host]` cases.
- 2026-11-06: Spikes of implementation steps 1, 2, and the v86 backend, with Zig 0.16, v86 0.5.473, Node 24.22, and Chromium 153, refine the design. The mechanisms hold as proposed: three coroutines kept their own `__stack_pointer`, `up`, `fs_plan`, and `errno` across parks, a longjmp from ten frames deep after a park landed, and a park and resume costs about 0.4 µs. v86 and a wasi-libc module shared one memory without overlap. On v86, a syscall round trip (halt exit, Ureg write, clearing `in_hlt`, `main_loop`) costs about 3 µs, and faults, x87/SSE, CR3 switches, and JIT dirtying behave as described. The refinements:
  - **Node 24.** Node 22's V8 has only the old JSPI API (`WebAssembly.Suspender`); `WebAssembly.Suspending` and `promising` need Node 24 or later, where they're on by default. That's the Node the integration suite uses.
  - **Build flags.** wasi-libc's `rt.c` needs `-mllvm -wasm-enable-sjlj` as well as `-mexception-handling`, or it fails with "undefined tag symbol cannot be weak". drawterm's `dtos.h` knows only named OSes, so kern builds with `-Dlinux`, plus `-D_WASI_EMULATED_SIGNAL`, `_PROCESS_CLOCKS`, `_MMAN`, and `_GETPID`; the vendored tree stays unmodified. With those, 278 of kern's 283 C files compile, devfs-posix.c included. The other five: `posix.c` (replaced by `os-wasm.c`), `devip-posix.c` (needs a stub `so_*` layer, since devip.c links against it even with `#I` masked), `getcallerpc.c` (no `__builtin_return_address` on wasm; returns 0), `rootdial.c` (Unix sockets; left out of web builds) and `glue.c`'s `getuid` (a stub).
  - **Stack overflow.** A canary word at a stack's low end missed an overflow that ran 56 KiB past an 8 KiB stack, since frames skipped over the word. `h9_park` and coroutine exit also compare the stack pointer with the stack's low end, which caught it; the canary stays as a second check.
  - **Memory order.** wasi-libc's malloc claims only up to the module's declared minimum (`__heap_end`) and grows from there. The order matters because v86's `allocate_memory` grows the memory from about 9.2 MiB, so called before h9 is instantiated it puts guest RAM across h9's 16 MiB base. WASI's `_initialize` makes h9's first allocation. `--global-base` at 10 MiB would leave less unused memory between the two.
  - **Preemption.** When a slice ends without a halt, the CPU is still at ring 3 and there's no Ureg on the kernel stack. `run` builds the Ureg from v86's register block (`reg32`, the instruction pointer, `sreg`, `get_eflags`), then returns the CPU to ring 0 before parking: it writes `cpl`, CS and SS with their cached base, limit, and access bytes, `is_32` and `stack_size_32`, and calls `full_clear_tlb` and `update_state_flags`, as v86's own `set_state` does. A preempted context then resumes through the restore path like any other. `scripts/pins.sh` records those offsets too (`segment_access_bytes` 512, `sreg` 668, `segment_is_null` 724, `segment_offsets` 736, `segment_limits` 768, `is_32` 804, `stack_size_32` 808). A jitted slice ends after 1.0 to 1.2 ms.
  - **JIT glue.** `codegen_finalize` compiles synchronously, in a Worker, and under Node, but `codegen_finalize_finished` panics in v86 when called from inside it. The glue queues it and calls it after `main_loop` returns.
- 2026-11-07: Steps 1 to 6 and most of step 7 are built: `zig build web`, `h9-node`, the v86 backend, the `[12]` cases, the demo page, and its Playwright check (`zig build web-test`). Under Node 24, `zig build integration -Dweb` passes every case that runs there. [websocket-9p](websocket-9p.md)'s step 8 is built too: WebSocket roots, `createMachine`'s URL root, and `/net/ws`. The status is implemented: `tests/backends.zig`'s i386 cases on v86 under Node and `-Dv86=source` were dropped from Done when, since the integration cases cover the backend through the CLI and the pinned, hash-checked `v86.wasm` is enough. Choices and refinements:
  - **Every Suspending import is a park.** The console read and the signal wait suspend as `park` does, so they save and restore the same per-thread state (`coro.blocking`); without that, a coroutine woken from a read ran on another's stack.
  - **Node's WASI** crashes Node ("IsOnCentralStack") when wasm calls its functions directly from a JSPI stack, since V8 takes its fast API path. `h9-node` wraps each in a JS function. WASI has no realpath, so `h9-node` resolves symlinks with readlink one component at a time.
  - **Modes.** WASI's stat has no permission bits, so devfs gave every file mode 0, which `#O` took as unwritable. The web build wraps devfs in `src/kern/devtab.c` to report `rwxrwxr-x`; the policy still decides access. The vendored tree stays unmodified.
  - **Network.** As websocket-9p's step 8 says, `--net=outbound` (the default, as natively) and `enable` bind `#ℏ` alone at `/net`, so `/net/ws` is the guest's network; `disable` masks `#ℏ`. `#I` is always masked. `--net-allow` checks a `/net/ws` connect's name or literal address, and the plan's caveat says resolved addresses can't be checked, since the browser resolves names itself.
  - **WebSockets.** `h9-web.js`'s `h9_ws_*` imports use the runtime's `WebSocket`, the browser's or Node's. A stream's coroutine parks in `h9_ws_recv`, which hands over as many queued binary messages as fit in one call, since 9P is a byte stream. A server that selects no subprotocol can't be a root there, as it can natively, since the browser fails a handshake that offered subprotocols and got none. A browser doesn't say why a connection failed, so a refused connection and a handshake's HTTP status are both "connection failed". `--root-header`, `--root-ca`, and `header` in `ctl` are errors, the browser uses its own proxy settings, and a page can't send pings, so there's no keepalive. `createMachine({ root: 'wss://…' })` runs over a 9P server with an empty WASI tree, and the demo page takes `?root=`.
  - **Node's exit.** `h9-node` ends by letting Node's event loop run out instead of calling `process.exit`, which deadlocked once in a suite run: V8's platform shutdown waited for a background Maglev compile that was itself waiting for a GC on the main thread.
  - **Stacks.** The suite's deepest use at a park was 149 KiB, in the first process's syscall path in a Debug build, so stacks are 320 KiB. `H9_TEST_KSTACK` sets every coroutine's stack, for the overflow case, and `H9_TEST_STACK_LOG` makes `h9-node` log the deepest use.
  - **Root archive.** `root.h9a` is h9's own format (paths, modes, and data, from `tools/webroot.zig`), served read-only by `src/web/wasi-mem.js`: writes go to the root's overlay as on native hosts. It's 3.5 MB.
  - **The page's API.** `createMachine`'s `policy` takes Policy's fields under their CLI names and passes them as flags, so the page and the CLI share one parser. `memory` defaults to h9's 256 MiB.
  - **Skips.** Besides the TTY and signal cases, the web run skips net-policy's and 9p-roots' cases by tag (5 and 13), a 9P root over TCP, and the case that copies `h9` alone, since `h9-node` needs `h9.wasm` beside it. websocket-9p's cases run, except the eight on headers, proxies, `--root-ca`, and keepalive pings, and the one with a server that selects no subprotocol. Their 9P servers are a native h9 on the emulator behind `tests/wsrelay.zig`, since the web host can't listen, so they need `-Dweb -Demu=unicorn`, and skip without it. The relay now sets `TCP_NODELAY`: its split mode writes messages of a few bytes, which Nagle's algorithm held for the last one's ACK, slowing a run to seconds.
  - **CPUs.** `--cpus 1` lets a process that spins without system calls keep the only CPU, as on native hosts, so the RFMEM case runs with two and four.
- 2026-11-10: `createMachine` takes `layers`, root archives unpacked in order over `root`'s archive (or alone, with no `root.h9a`), each a URL or `{ url, at }`, where `at` is the directory it lands in (default `/`). A later file replaces an earlier one and directories merge, as `putNode` does. They're one tree at WASI's `/`, so a 9front tree in a Linux tree's `/9` is a second `--root /9` in argv, which `main.zig` already tells apart from the Linux one. The demo's `?linux` mode stacks `nine-arm64.h9a`, the arm64 slim root (`zig build slim -Darch=arm64`, from arm64 libraries cross-compiled in the 386 root) packed by `src/web/nine-arm64.list`, at `/9`, so busybox has `/9/bin/rc` and `/9/bin/wsmount` and can mount a host's served `/net` ([linux-net](linux-net.md), Updates). A build without that tree leaves it out, and the page runs without it.
- 2026-11-11: Two costs that grow with memory, found running Claude Code (an arm64 Bun binary of 285 MB) on ha64 with `--memory 1G`.
  - **memory.grow.** V8 runs a full GC on each `memory.grow` once the memory is large, since the detached buffer counts as external memory until one runs: a few ms each at a GiB or two. std's wasm allocator grows 64 KiB at a time, about 2,000 times for `claude --help`, so a quarter of the run was GC. `src/web/heap.zig`, std's BrkAllocator with its memory taken in steps of at least 32 MiB, is `std.heap.page_allocator` on the web host (main.zig's `os.heap`) and the backends' allocator (`vmm.host_gpa`). Malloc still uses std's, but little of h9's memory comes from it.
  - **Pointers past 2 GiB.** wasm hands JS an i32 signed, so with guest memory over about 1G, h9's heap is past 2 GiB and WASI calls got negative pointers: Node's WASI returned EINVAL, and `wasi-mem.js`'s DataViews threw. Both hosts make every i32 WASI argument unsigned, since all of them are pointers, lengths, fds, or flags.
