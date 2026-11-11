# Developing h9

Building, testing, and releasing h9, and where things are in the tree. The
[manual](MANUAL.md) is for using h9, [SPEC.md](SPEC.md) describes how it
works, and [design/](design/README.md) is how changes to it are proposed.
[AGENTS.md](AGENTS.md) has the conventions for changing the code.

## Setup (macOS arm64)

Requires Zig 0.16.x and Xcode (for the macOS SDK and `codesign`).

```sh
. scripts/env.sh               # Zig cache and tools live in .local/ (gitignored); puts zig-out/bin (h9) on PATH
./scripts/fetch.sh             # reference sources (9front at the pinned release), 9front arm64 image, prebuilt and patched-source Unicorn into .local/ (or name parts: fetch.sh iso386)
zig build mkroot               # extracts the 9front root tree into .local/9front/root (~1 min, ~250 MB)
```

`zig build mkroot` ([tools/mkroot.zig](tools/mkroot.zig)) boots the pinned
image headless in QEMU (`brew install qemu`), tars the file system out onto a
scratch disk, and unpacks it into `.local/9front/root-<release>`, with
`.local/9front/root` linked to it. The image itself isn't modified. It's the
host-tree root h9 serves as `/`. Boot kernels, `/sys/doc`, and `/sys/src` are
left out; pass `--src` to keep `/sys/src`, which
[self-hosting](design/0010-self-host.md) needs. Options go after `--`:
`zig build mkroot -- --src`.

The tree has the host's architecture's binaries unless `--arch` names
others (`--arch arm64`, `--arch 386,amd64`). The image's binaries are arm64;
`/386` and `/amd64` are filled by cross-compiling `/sys/src` inside h9
(`objtype=386 mk install`), which takes a built `zig-out/bin/h9` (or `$H9`).
Each architecture takes a few minutes on an arm64 hypervisor, but about an
hour on the emulator, which x86\_64 hosts need because the compilers are
arm64. On an existing tree it builds the host's architecture only if it's
missing, and what `--arch` names again. `zig build integration -Darch=386`
then runs the integration cases with the 386 binaries on the emulator.

Pinned upstream versions are in [scripts/pins.sh](scripts/pins.sh).

drawterm is committed under `third_party/drawterm` as a squashed git subtree,
so a fresh checkout builds without network access. To move to a new upstream
revision, bump `DRAWTERM_REV` and run `./scripts/vendor-drawterm.sh` on a
clean tree; it merges upstream into the subtree and keeps our local changes.

### Linux (KVM)

On Linux, h9 uses KVM ([kvm](design/0016-kvm.md)) on arm64 and x86\_64. It
needs read and write access to `/dev/kvm`, usually through the `kvm` group
(`sudo usermod -aG kvm $USER`, then log in again), and inside a VM, nested
virtualization. `h9 --check` says which is missing. `zig build mkroot` needs
`qemu-system-aarch64`, `qemu-img`, and `bsdtar` (Debian and Ubuntu:
`qemu-system-arm qemu-utils libarchive-tools`). KVM runs the host's
architecture, so on x86\_64 the root needs `/amd64`, which `zig build mkroot`
builds there by default, with an emulator h9 running the tree's arm64
compilers:

```sh
zig build -Demu=unicorn -Dtarget=x86_64-linux-musl --prefix .local/h9-emu
H9=.local/h9-emu/bin/h9 zig build mkroot     # /amd64 on x86_64 hosts
zig build integration -Darch=amd64     # the cases on KVM (and emu, if built in)
```

The KVM backend blocks `SIGRTMIN + 1` in the threads that run vCPUs and uses
it to kick them; an embedder must leave it to h9.

### Linux without KVM (native)

On x86\_64 Linux hosts without a usable KVM (containers, CI, and cloud VMs
without nested virtualization), h9 can run amd64 binaries on the native
backend ([native-backend](design/0095-native-backend.md)): guest code runs
directly on the host CPU in a small stub process per address space (with a
thread per thread of a Linux program), and the kernel turns every guest
syscall into a signal the stub hands to h9 (Syscall User Dispatch, Linux 5.11
or later, with a seccomp filter behind it). It's built into every Linux
x86\_64 `h9`, but since it shares h9's process and isn't a security boundary,
`auto` never picks it: it takes an explicit `--backend native`. Compute runs
at native speed, many times faster than the emulator. Before using it, h9
checks that a guest syscall traps with each of a list of values in AX, and
`h9 --check` says why it can't run where it can't. A root built on such a
host (or unpacked from the release's amd64 ISO) runs the integration cases
quickly:

```sh
zig build integration -Darch=amd64 -Dbackends=native
```

`-Dbackends` picks the backends the cases run on (by default every one built
in that runs here), and the Go cases run on native when it's among them.

## Build

```sh
zig build          # builds and ad-hoc signs zig-out/bin/h9 with h9.entitlements
zig build test     # unit tests, and the backend tests on every backend built in (not the integration cases)
zig build kern     # compiles drawterm's kern and the libraries it uses
zig build embed    # builds docs/embedding/embed.zig, the embedding guide's example, as zig-out/bin/embed
zig build integration  # real 9front binaries from the root tree through the h9 CLI
zig build proposal -Dp=baseline  # one proposal's demos and integration cases (by slug or id)
zig build design -- check        # validate design/ and the test tags (also list, ready, graph, new, file)
zig build mkroot -- --src        # build the root tree from the pinned image (also --force, --arch arm64,386,amd64)
zig build -Dhost-cmd              # also build in host commands (#C, --host-cmd, hcmd), off by default (design/host-cmd.md)
zig build slim     # 9box, 9front's commands as one multi-call binary, and a slim root around it in .local/9front/slim-<release>-<arch>
zig build web      # the browser host into zig-out/web (h9.wasm, h9-web.js, h9-node, the demo page)
zig build integration -Dweb   # the integration cases through h9-node on h86 (Node 24 or later); -Darch=arm64 for ha64
zig build web-test # the demo page, and the canvas cases (tests/web/gfx.mjs), in Chromium with Playwright, and hcpu-web
zig build hcpu-web # the wasm emitter's suite (tests/jit/suite.mjs) in Chromium
zig build x86-jit  # the 386 JIT's [x86-jit] cases (tests/x86.zig) on T0 and T1; zig build hcpu runs them too
zig build x64-jit  # hx64's [174] cases (tests/x64.zig) on T0 and T1; zig build hcpu runs them too
zig build -Demu=hcpu -Dhcpu-debug  # src/interp and src/jit built Debug too (by default they're ReleaseFast in a Debug h9)
zig build clean    # removes zig-out and .zig-cache (not the fetched .local tree)
```

`zig build slim` builds [9box](design/0064-multicall.md) inside the h9 it
just built, against the root tree: 9front's own commands, compiled from the
pinned source with their globals renamed so they share one link, chosen by
the name they run as: the 42 commands basic operation needs.
`-Dslim-links=hard` (hard links to `9box`, the default) or `stub`
(`#!/bin/9box -!` files, for trees without hard links), and `-Darch`;
`-Dslim-links=copy` builds nothing and makes `slim-copy-*` with the same
commands copied from the root, to measure the box against
([tests/fixtures/multicall/execloop.rc](tests/fixtures/multicall/execloop.rc)).
It needs `/sys/src`, from `zig build mkroot -- --src` or the checkout
`fetch.sh` makes, and takes a few minutes on the emulator. The tree is
`9box`, its links, `rcmain`, and the mount points, and runs with
`h9 --root .local/9front/slim-11952-arm64`. The `[64]` cases use it, and skip
without it.

`zig build` embeds the same trees as h9's
[built-in root](design/0087-builtin-root.md), `#Hroot`, which h9 uses when it
finds no root tree, so `h9 --rc 'ls'` works with nothing but the binary. It
takes `slim-<release>-<arch>` for each architecture the build runs (the
target's, and with `-Demu=unicorn` also `amd64` and `386`) from
`-Dbuiltin-root` (default `.local/9front`). An architecture without a tree
for the pinned release gets the built-in root's directories only, and
`zig build` warns; `-Drelease` fails instead.

h9's own guest commands, the rc scripts in [src/guest/](src/guest), are
embedded in the binary and served by `#H`. Only rc scripts and data go there:
the build fails on an executable that doesn't start with `#!/bin/rc`. Debug
builds also serve the test-only scripts in `tests/fixtures/guest/` for the
integration cases; release builds don't (`-Dguest-test` overrides it).

### The emulator, and Windows

The emulator backend links the prebuilt Unicorn (GPLv2) fetched by
`scripts/fetch.sh`, so it's opt-in and never part of the MIT `h9` build. It
ships separately as `h9-emu` (see [Releases](#releases)):

```sh
zig build -Demu=unicorn                              # macOS arm64
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl  # Linux arm64 (also x86_64-linux-musl)
zig build proposal -Dp=baseline -Demu=unicorn        # the baseline demos, adding h9 --backend emu ./hello
zig build bench -Demu=unicorn                        # compute and syscall speed, emu vs the hypervisor
```

`-Dunicorn=source` builds Unicorn from the patched source instead
([third_party/unicorn](third_party/unicorn/README.md)); `scripts/fetch.sh`
fetches it. The prebuilt libraries exist for macOS arm64 and Linux musl only,
so Windows (`-Dtarget=aarch64-windows` or `x86_64-windows`) always builds
from source. kern builds for Windows with drawterm's win32 files, so h9.exe
runs programs on the emulator, and host paths are `/C:/...` in `#U`. On
Windows x86\_64, h9.exe also has the WHP backend ([whp](design/0017-whp.md)):
it needs the Windows Hypervisor Platform feature (Settings >
Optional features, or `DISM /Online /Enable-Feature
/FeatureName:HypervisorPlatform`, then restart), and loads
`WinHvPlatform.dll` only when it's used, so h9.exe still starts, and `auto`
falls back to the emulator, without it.

### Graphics

`-Dgfx` picks the GUI backend for `--gfx` ([gfx](design/0015-gfx.md)):
drawterm's Cocoa on macOS and Win32 on Windows by default, `none` on Linux.
`-Dgfx=x11` builds the X11 backend for Linux, which links the host's libX11
(and needs the libXt headers), so it builds natively against glibc, not for
a musl target. `-Dgfx=none` leaves graphics out; `-Dgfx=headless` is a screen
in memory, which the backend tests use whatever `-Dgfx` is. `zig build web`
always builds `web`, the browser host's canvas backend
([browser-gfx](design/0120-browser-gfx.md)), unless `-Dgfx=none` leaves it
out.

### Wine

`winedraw` is a Wine display driver that draws through the window's draw
files, which Linux programs see at `/dev/9`, one draw layer per top-level
window, and turns `/dev/mouse` and `/dev/kbd` into input
([wine-draw](design/wine-draw.md), a draft). It builds against Wine 11.0's
headers, and runs in an amd64 Linux root with Wine in it:

```sh
scripts/fetch.sh wine          # Wine's include/ at the pinned tag, into .local/src/wine
zig build wine                 # zig-out/wine/x86_64-{unix,windows}/winedraw.{so,drv}
scripts/wine-root.sh           # Alpine amd64 with Wine 11, at .local/linux/wine-amd64
```

[Running Windows programs](docs/windows.md) walks through installing it,
from the root to a prefix that lasts between runs.

`zig build wine` builds the driver for i386 too, in `zig-out/wine/i386-*`,
with `roundf386.so`: Alpine's 32-bit musl gets `roundf` wrong at the x87
precision Windows programs set, which makes every window 96 times too big,
so 32-bit Wine runs with it in `LD_PRELOAD`. The [Wine page](site/wine.html)'s
demo is 32-bit Wine in the browser host (`?wine`), over `wine.h9a`:

```sh
scripts/wine-root.sh 386       # Alpine x86 with Wine 11, at .local/linux/wine-386
zig build -Demu=hcpu -Dgfx=headless -Doptimize=ReleaseSafe
scripts/wine-web.sh            # .local/linux/wine-web: the driver and a prefix, made by h9 on h86
zig build web                  # packs it into zig-out/web/wine.h9a, from src/web/wine.list
```

### Browser host

`zig build web` builds h9 for wasm32-wasi
([browser-host](design/0012-browser-host.md)). It runs 9front's 386 binaries
on h9's own CPU (h86, with its wasm JIT tier), and needs JavaScript Promise
Integration (Chrome 137 or later, Node 24 or later). With a 386 root tree
(`zig build mkroot -- --arch 386`, linked or copied as
`.local/9front/root386`, or `-Dweb-root=DIR`) it also packs the demo page's
root archive, `root.h9a`, from the paths in `src/web/root.list`.

```sh
zig-out/web/h9-node --root .local/9front/root386 --rc 'ls /bin | wc -l'   # the CLI under Node
zig-out/web/h9-node --root ws://localhost:8080/9p ls /   # over a WebSocket 9P server
(cd zig-out/web && python3 -m http.server)   # then open http://localhost:8000 for an interactive rc
zig build integration -Dweb -Droot=$PWD/.local/9front/root386
```

A 386 root for the archive can also come straight from the release's 386 ISO,
without cross-compiling: `scripts/fetch.sh iso386` fetches it, and
`zig build isoroot -- .local/9front/9front-<release>.386.iso .local/9front/root386`
([tools/isoroot.zig](tools/isoroot.zig)) unpacks it in about 20 seconds.
That's how the [pages workflow](.github/workflows/pages.yml) builds the demo on
each push to main and publishes it with the project page,
[site/index.html](site/index.html), to GitHub Pages.

The demo page runs over a WebSocket 9P server with `?root=ws://…/9p`. The
integration run's WebSocket cases need `-Demu=unicorn` too (with
`-Dtarget=x86_64-linux-musl` on Linux), since their 9P server is a native h9.

The web host's only network is WebSockets: `#I` is masked, and `--net`
(outbound by default) binds `/net/ws` alone at `/net`. The browser does the
handshake, TLS, and proxies, so `--root-header`, `--root-ca`, and `header` in
`ctl` are errors there, and `--net-allow` can't check what a name resolves
to. `#C` is masked and `--host-cmd` is a usage error. A page embeds a
machine with `createMachine({ root, memory, policy, terminal })` from
`h9-web.js`, where `root` is a root archive's URL or a `ws://` or `wss://`
URL; each machine runs in its own Worker.

## Tests

The demos and the integration tests use the root tree from
`zig build mkroot`, or `-Droot=DIR`. Without a tree, the integration tests
skip and only the hello demos run. Each case is tagged with the proposal it
proves (`test "echo [baseline]"`); cases for a proposal that isn't implemented
yet skip in `zig build integration` unless `-Dpending` is given, and
`zig build proposal -Dp=<slug or id>` runs one proposal's cases whatever its
status. Interactive cases run h9 on a terminal the test creates
([tests/term.zig](tests/term.zig): a pty, or ConPTY on Windows), so they need
no human and no `ssh -t`.

[tests/backends.zig](tests/backends.zig) runs small programs on every backend
built in and checks that each gives the same output and syscall trace.
[tests/integration.zig](tests/integration.zig) runs real binaries from the
root tree through `h9` itself, checking output and exit codes.
`zig build integration` splits the cases four ways by a hash of their names
and runs the four parts at once, since the cases mostly wait on h9,
terminals, and sockets; `-Dshards=N` picks another count, and `-Dshards=1`
runs them in one process. `zig build test` likewise runs
[src/hcpu.zig](src/hcpu.zig)'s tests as four binaries split by name.
`zig build install-tests` installs both, built for `-Dtarget`, as
`zig-out/bin/backend-tests` and `zig-out/bin/integration-tests`, to run in a
VM.

`zig build` also writes the test binaries `zig-out/fixtures/hello` (arm64) and
`zig-out/fixtures/hello-amd64`. They're hand-assembled a.outs (see
[tests/fixtures/hello.zig](tests/fixtures/hello.zig)) because Zig no longer
links Plan 9 a.out.

The Go programs in [tests/fixtures/go](tests/fixtures/go) are built by
`zig build go-fixtures` into `zig-out/fixtures/go`, as
`GOOS=plan9 GOARCH=amd64` with `GOTOOLCHAIN=go$GO_VERSION` from
[scripts/pins.sh](scripts/pins.sh), so any installed Go fetches the same
toolchain. `zig build integration` builds them when `go` is on `PATH` and h9
is built with `-Demu=unicorn` or the cases run on the native backend, and
their cases run on native when it's in the list, else on the emulator;
without Go they skip. They don't need the root tree.
`zig build go-stdtest -Demu=unicorn` runs Go's own tests for `time`,
`syscall`, `os`, and `runtime` on the emulator and prints pass, skip, and
fail counts for each ([scripts/go-stdtest.sh](scripts/go-stdtest.sh), with
the tests it skips in `scripts/go-stdtest.skip`; `zig build go-stdtest -- os`
runs one package). It's for finding gaps, not a gate, and nothing depends on
it.

### Test VMs

[scripts/lima](scripts/lima/README.md) has Lima VMs (arm64 Linux, macOS, and
Windows, plus emulated x86\_64 Linux) for testing the emu backend on hosts
without a usable hypervisor:

```sh
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm up linux
scripts/lima/vm push linux zig-out/linux/bin/h9 zig-out/fixtures/hello
scripts/lima/vm shell linux ./h9/h9 --backend emu ./h9/hello
scripts/lima/vm push-root linux             # the root tree, into ~/h9/root

zig build install install-tests -Demu=unicorn -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm test linux                  # backend and integration tests on the emulator
```

## Releases

Each GitHub release has two sets of binaries, built by
`scripts/release.sh [version]` into `dist/<version>/` from a clean checkout:

| Asset | License | Contents |
| --- | --- | --- |
| `h9-<version>-<target>` | MIT | `h9` with the hypervisor backends only (macOS arm64 for now) |
| `h9-emu-<version>-<target>` | GPLv2 | `h9-emu`: h9 built with `-Demu=unicorn`, for macOS arm64, Linux arm64 and x86_64 (musl, static), and Windows arm64 and x86_64 |
| `h9-emu-<version>-source.tar.gz` | GPLv2 and MIT | complete corresponding source for `h9-emu`: the h9 tree plus Unicorn's patched source in `.local/src/unicorn` |
| `h9-web-<version>.tar.gz` | MIT | the browser host: `h9.wasm`, `h9-web.js`, `h9-node`, the demo page, and its root archive |
| `SHA256SUMS` | | checksums |

`h9-emu` takes the same flags as `h9` and runs on hosts without a usable
hypervisor. It links Unicorn Engine, so the binary as a whole is GPLv2, with
`COPYING`, `NOTICE`, and the MIT notices in each archive; see
[LICENSE](LICENSE). The script builds every binary from the unpacked source
tarball, with Unicorn from source (`-Dunicorn=source`), so the tarball is
exactly what was built. It needs `scripts/fetch.sh` to have been run and runs
on macOS, which cross-compiles the other targets.

Release builds report the release's version in `--version` and `--check`;
development builds report `git describe` (`-Dversion=V` overrides it).

## Layout

| Path | Contents |
| --- | --- |
| `src/main.zig`, `src/cli.zig`, `src/stdin.zig`, `src/hostsig.zig`, `src/tools.zig` | CLI: entry point, flag parsing with no I/O, the host stdin reader (cancellable, for the console's reader thread), Ctrl-C, hangup, and raw mode on the host terminal, and `--check`/`--version` |
| `src/gfx.zig`, `src/kern/gfx*.c`, `src/kern/nogfx.c` | `--gfx`: the window claim and `h9.gfx.main`, the kernel glue around drawterm's GUI backends (lazy `#i`, the kbdfs `/dev/kbd`, the clipboard), the headless test backend, and the stubs for builds without graphics |
| `src/wine/` | winedraw, the Wine display driver over Plan 9 draw: its Unix library, its PE side, and `draw9.h`, a small draw client the `drawpeek` fixture shares |
| `src/root.zig` | library root; [docs/embedding.md](docs/embedding.md) explains using it |
| `docs/` | guides that go further than the manual; `docs/embedding/embed.zig` is the embedding guide's example program |
| `src/machine.zig` | one machine: builds its namespace, runs a process, and serves its syscalls |
| `src/consin.zig` | a machine run's console input: the reader thread a guest's console read waits on, so notes can interrupt it |
| `src/policy.zig` | the sandbox policy: profiles, the compiled plan, `--print`, and the access rules devfs checks |
| `src/kern.zig`, `src/kern/` | the Zig/C seam into drawterm's kern; boot and spawn (`glue.c`), process records and notes (`proc.c`), our device table, the machine console `#y`, devenv, and devproc ported from 9front, the copy-on-write overlay device `#O` (`devoverlay.c`), h9's guest commands `#H` (`devhtools.c`), and the devfs policy hooks (`fscheck.c`) |
| `src/guest/` | h9's own guest commands (rc scripts), as the guest sees them under `#H`; embedded by the build through `tools/guesttree.zig`. `src/guest-hostcmd/` adds `hcmd` under `-Dhost-cmd` |
| `src/syscall.zig`, `src/guestmem.zig` | the 9front syscall table, and checked access to guest memory |
| `src/loader.zig` | loads an a.out into an address space, builds the stack and Tos |
| `src/aout.zig` | a.out parser and arch layouts |
| `src/vmm.zig`, `src/vmm/` | hypervisor interface and backends (HVF, KVM, WHP, native, and emu, on Unicorn or h9's own CPUs, which the browser host uses), with the guest-physical allocator and page tables the hypervisor backends share |
| `src/hcpu.zig`, `src/jit/`, `src/interp/` | h9's own CPUs for the emulator (`-Demu=hcpu`): the JIT's IR and its reference evaluator, the runtime ABI, the emitters (arm64, wasm), the front ends (`a64/`), and the interpreters and software TLB the two tiers share. `src/jit/README.md` has the contracts |
| `src/web.zig`, `src/web/` | the browser host: coroutines on JSPI, its `std.Io` and console, the JS host (`h9-web.js`, `h9-node`, `worker.js`, `wasi-mem.js`) and the demo page |
| `src/arch/` | per-architecture Ureg/ABI and the guest shims |
| `third_party/drawterm` | vendored drawterm (git subtree; kern and libraries). Local changes: the sandbox hooks in `kern/devfs-posix.c` and `kern/devfs-win32.c` |
| `third_party/unicorn`, `build/unicorn.zig` | patches, per-host config headers, and the Zig build for Unicorn from source (GPLv2; source fetched, not vendored) |
| `tests/backends.zig` | backend conformance tests |
| `tests/integration.zig` | real 9front binaries through the h9 CLI |
| `tests/term.zig` | a pty (ConPTY on Windows) for the interactive integration cases |
| `tests/fixtures` | test programs and binary generators; `segattach/` holds the arm64 programs for the segattach backend cases and `gfx/` those for the `[gfx]` cases, assembled at build time |
| `tests/web/` | the browser host's Playwright check |
| `tests/jit/` | the wasm emitter's checks: a runtime module standing in for h9.wasm, a random region generator, the suite (`suite.mjs`) and its Node and Chromium drivers, and `bench.mjs`, which times installs and tier-up in V8 |
| `tools/mkroot.zig` | `zig build mkroot`: builds the 9front root tree from the pinned image |
| `scripts/release.sh` | builds the release assets (`h9`, `h9-emu` and its source, `h9-web`) into `dist/` |
| `.local/` | gitignored: tools, caches, upstream clones, 9front images, prebuilt Unicorn, test VMs |
