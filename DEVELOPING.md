# Developing h9

Building, testing, and releasing h9, and where things are in the tree. The
[manual](MANUAL.md) is for using h9, [SPEC.md](SPEC.md) describes how it
works, and [design/](design/README.md) is how changes to it are proposed.
[AGENTS.md](AGENTS.md) has the conventions for changing the code.

## Setup (macOS arm64)

Requires Zig 0.17.x and Xcode (for the macOS SDK and `codesign`).

```sh
. scripts/env.sh               # Zig cache and tools live in .local/ (gitignored); puts zig-out/bin (h9) on PATH
./scripts/fetch.sh             # 9front source at the pinned release, 9front arm64 image, prebuilt Unicorn (zig build lockstep's oracle), and the Alpine roots into .local/ (or name parts: fetch.sh iso386, fetch.sh alpine-amd64)
zig build mkroot               # extracts the 9front root tree into .local/9front/root (~1 min, ~250 MB)
```

`zig build mkroot` ([tools/mkroot.zig](tools/mkroot.zig)) boots the pinned
image headless in QEMU (`brew install qemu`), tars the file system out onto a
scratch disk, and unpacks it into `.local/9front/root-<release>`, with
`.local/9front/root` linked to it. The image itself isn't modified. It's the
host-tree root h9 serves as `/`. Boot kernels, `/sys/doc`, and `/sys/src` are
left out; pass `--src` to keep `/sys/src`, which
[self-hosting](design/epoch-0/self-host.md) needs. Options go after `--`:
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

On Linux, h9 uses KVM ([kvm](design/epoch-0/kvm.md)) on arm64 and x86\_64. It
needs read and write access to `/dev/kvm`, usually through the `kvm` group
(`sudo usermod -aG kvm $USER`, then log in again), and inside a VM, nested
virtualization. `h9 --check` says which is missing. `zig build mkroot` needs
`qemu-system-aarch64`, `qemu-img`, and `bsdtar` (Debian and Ubuntu:
`qemu-system-arm qemu-utils libarchive-tools`). KVM runs the host's
architecture, so on x86\_64 the root needs `/amd64`, which `zig build mkroot`
builds there by default, with h9's emulator running the tree's arm64
compilers:

```sh
zig build                              # h9, with hcpu built in
zig build mkroot                       # /amd64 on x86_64 hosts
zig build integration -Darch=amd64     # the cases on KVM and hcpu
```

The KVM engine blocks `SIGRTMIN + 1` in the threads that run vCPUs and uses
it to kick them; an embedder must leave it to h9.

### Linux without KVM (sud)

On x86\_64 Linux hosts without a usable KVM (containers, CI, and cloud VMs
without nested virtualization), h9 can run amd64 binaries on the sud
engine ([native-backend](design/epoch-0/native-backend.md)): guest code runs
directly on the host CPU in a small stub process per address space (with a
thread per thread of a Linux program), and the kernel turns every guest
syscall into a signal the stub hands to h9 (Syscall User Dispatch, Linux 5.11
or later, with a seccomp filter behind it). It's built into every Linux
x86\_64 `h9`, but since it shares h9's process and isn't a security boundary,
`auto` never picks it: it takes an explicit `--engine sud`. Compute runs
at native speed, many times faster than the emulator. Before using it, h9
checks that a guest syscall traps with each of a list of values in AX, and
`h9 --check` says why it can't run where it can't. A root built on such a
host (or unpacked from the release's amd64 ISO) runs the integration cases
quickly:

```sh
zig build integration -Darch=amd64 -Dengines=sud
```

`-Dengines` picks the engines the cases run on (by default every one built
in that runs here), and the Go cases run on sud when it's among them.

## Build

```sh
zig build          # builds and ad-hoc signs zig-out/bin/h9 with h9.entitlements
zig build test     # unit tests, and the engine tests on every engine built in (not the integration cases)
zig build kern     # compiles drawterm's kern and the libraries it uses, with the parts ported to Zig (src/kern/port.zig)
zig build kern-test  # the ported kernel's own cases (src/kern/*.zig), on the native namespace kernel; zig build test runs them too
zig build sched-test  # the scheduler's kernel stacks and park and resume (src/kern/sched/), with no kernel or engine; compiled only for a -Dtarget the host can't run, and for wasm32 run through Asyncify under Node if Binaryen's wasm-opt is on PATH; zig build test runs them too
zig build embed    # builds docs/embedding/embed.zig, the embedding guide's example, as zig-out/bin/embed
zig build integration  # real 9front binaries from the root tree through the h9 CLI
zig build proposal -Dp=baseline  # one proposal's demos, web cases, and integration cases, by slug
zig build conformance            # tests/conformance/ns.rc on h9, against 9front's transcript; -- --oracle records that under QEMU
zig build design -- check        # validate design/, the test tags, and links to design/ (also list, ready, new, propose, log, sign, archive)
zig build mkroot -- --src        # build the root tree from the pinned image (also --force, --arch arm64,386,amd64)
zig build slim     # 9box, 9front's commands as one multi-call binary, and a slim root around it in .local/9front/slim-<release>-<arch>
zig build web      # the web host into zig-out/web (h9.wasm, h9-web.js, h9-node, the demo page)
zig build integration -Dweb   # the integration cases through h9-node on h86 (Node 24 or later); -Darch=arm64 for ha64
zig build web-test # the demo page, the canvas cases (tests/web/gfx.mjs), and the namespace kernel's machine cases (tests/web/nskernel-browser.mjs), in Chromium with Playwright, and hcpu-web
zig build nskernel # the namespace kernel into zig-out/nskernel (h9ns.wasm, h9ns.js, libh9ns.a, h9ns.h); -Dnskernel-hostfs keeps #U natively
zig build nskernel-test  # its cases: tests/nskernel.zig on the native library, then tests/web/nskernel.mjs under Node 24 or later (skipped on an older Node)
zig build libh9     # libh9, h9 behind a C ABI, into zig-out/libh9 (libh9.so, .dylib, or h9.dll, and h9.h)
zig build libh9-example  # docs/embedding/hello.c on libh9, as zig-out/bin/libh9-hello; zig build test runs it
zig build hcpu-web # the wasm emitter's suite (tests/jit/suite.mjs) in Chromium
zig build x86-jit  # h86's [hcpu] cases (tests/x86.zig) on T0 and T1; zig build hcpu runs them too
zig build x64-jit  # hx64's [hcpu] cases (tests/x64.zig) on T0 and T1; zig build hcpu runs them too
zig build -Dhcpu-debug  # src/engine/hcpu/interp and src/engine/hcpu/jit built Debug too (by default they're ReleaseFast in a Debug h9)
zig build clean    # removes zig-out and .zig-cache (not the fetched .local tree)
```

`zig build slim` builds [9box](design/epoch-0/multicall.md) inside the h9 it
just built, against the root tree: 9front's own commands, compiled from the
pinned source with their globals renamed so they share one link, chosen by
the name they run as: the 44 commands basic operation needs.
`-Dslim-links=hard` (hard links to `9box`, the default) or `stub`
(`#!/bin/9box -!` files, for trees without hard links), and `-Darch`;
`-Dslim-links=copy` builds nothing and makes `slim-copy-*` with the same
commands copied from the root, to measure the box against
([tests/fixtures/multicall/execloop.rc](tests/fixtures/multicall/execloop.rc)).
It needs `/sys/src`, from `zig build mkroot -- --src` or the checkout
`fetch.sh` makes, and takes a few minutes on the emulator. The tree is
`9box`, its links, `rcmain`, and the mount points, and runs with
`h9 --dir .local/9front/slim-11952-arm64`. The `[64]` cases use it, and skip
without it.

`zig build` embeds the same trees as h9's
[built-in root](design/epoch-0/builtin-root.md), `#Hroot`, which h9 uses when it
finds no root tree, so `h9 --rc 'ls'` works with nothing but the binary. It
takes `slim-<release>-<arch>` for each architecture the build runs (the
target's, `amd64`, and `386`) from
`-Dbuiltin-root` (default `.local/9front`). An architecture without a tree
for the pinned release gets the built-in root's directories only, and
`zig build` warns; `-Drelease` fails instead.

h9's own guest commands, the rc scripts in [src/guest/](src/guest), are
embedded in the binary and served by `#H`. Only rc scripts and data go there:
the build fails on an executable that doesn't start with `#!/bin/rc`. Debug
builds also serve the test-only scripts in `tests/fixtures/guest/` for the
integration cases; release builds don't (`-Dguest-test` overrides it).

### The emulator, and Windows

The hcpu engine is h9's own CPUs ([hcpu](design/epoch-0/hcpu.md)): ha64
for arm64, h86 for 386, and hx64 for amd64, each with a JIT (T1) and an
interpreter (T0). It's MIT and always built in on arm64 and x86-64
targets, so every `h9` has it, and `-Dno-jit` builds the interpreter
alone. There's no other emulator to build ([retire-unicorn](design/epoch-0/retire-unicorn.md)). `H9_HCPU_TIER=t0` or `t1` picks a
tier at run time, for tests:

```sh
zig build                                        # h9, with hcpu
zig build -Dtarget=aarch64-linux-musl            # Linux arm64 (also x86_64-linux-musl, and the Windows targets)
zig build test                                   # tests/engines.zig on T1 and on T0, and the CPUs' own cases
zig build integration -Dengines=hcpu             # the integration cases on hcpu
zig build integration -Dengines=hcpu -Djit-check # every compiled region checked against T0
zig build bench                                  # compute and syscall speed, hcpu against the hypervisor
```

Unicorn is kept as a test oracle only: `zig build lockstep`
([tools/lockstep.zig](tools/lockstep.zig)), and the fuzzers' lockstep
mode, check T0 against it an instruction at a time. They link the
prebuilt library that `scripts/fetch.sh unicorn` fetches, for macOS arm64
and Linux arm64 and x86\_64 (built for musl there), and `zig build
lockstep` fails with that hint without it. It's GPLv2, so nothing else
links it. kern builds for Windows with drawterm's win32 files, so h9.exe
runs programs on the emulator, and host paths are `/C:/...` in `#U`. On
Windows x86\_64, h9.exe also has the WHP engine ([whp](design/epoch-0/whp.md)):
it needs the Windows Hypervisor Platform feature (Settings >
Optional features, or `DISM /Online /Enable-Feature
/FeatureName:HypervisorPlatform`, then restart), and loads
`WinHvPlatform.dll` only when it's used, so h9.exe still starts, and `auto`
falls back to the emulator, without it.

### Graphics

`-Dgfx` picks the GUI backend for `--gfx` ([gfx](design/epoch-0/gfx.md)):
drawterm's Cocoa on macOS and Win32 on Windows by default, `headless` on
Linux. `-Dgfx=x11` builds the X11 backend for Linux, which links the host's
libX11 (and needs the libXt headers), so it builds natively against glibc,
not for a musl target. The headless screen, a screen in memory for
`--gfx=headless` ([headless-screen](design/epoch-0/headless-screen.md)), is linked
into every build with graphics; `-Dgfx=headless` is a build with only it.
`-Dgfx=none` leaves graphics out. The engine tests use the `-Dgfx` build's
headless screen, or a headless-only build with `none`, so `zig build test
-Dgfx=x11 -Dtarget=x86_64-linux-gnu` runs the `[gfx]` cases beside a
window backend. `zig build web`
always builds `web`, the web host's canvas backend
([browser-gfx](design/epoch-0/browser-gfx.md)), unless `-Dgfx=none` leaves it
out.

### Wine

`scripts/wine-root.sh` makes an Alpine amd64 root with Wine 11 in it, at
`.local/linux/wine-amd64`, for running Windows console programs
([Running Windows programs](docs/windows.md)). `winedraw`, the Wine
display driver over Plan 9 draw that gives Windows programs windows, and
the [Wine page](site/wine.html)'s browser demo are experimental and live on
the [`wine-draw` branch](https://github.com/progrium/hyper9/tree/wine-draw)
([wine-draw](design/wine-draw.md)).

### Web host

`zig build web` builds h9 for wasm32-wasi
([browser-host](design/epoch-0/browser-host.md)). It runs 9front's 386 binaries
on h9's own CPU (h86, with its wasm JIT tier), and needs JavaScript Promise
Integration (Chrome 137 or later, Node 24 or later). With a 386 root tree
(`zig build mkroot -- --arch 386`, linked or copied as
`.local/9front/root386`, or `-Dweb-root=DIR`) it also packs the demo page's
root archive, `root.h9a`, from the paths in `src/web/root.list`.

```sh
zig-out/web/h9-node --dir .local/9front/root386 --rc 'ls /bin | wc -l'   # the CLI under Node
zig-out/web/h9-node --url ws://localhost:8080/9p ls /    # over a WebSocket 9P server
(cd zig-out/web && python3 -m http.server)   # then open http://localhost:8000 for an interactive rc
zig build integration -Dweb -Droot=$PWD/.local/9front/root386
```

A 386 root for the archive can also come straight from the release's 386 ISO,
without cross-compiling: `scripts/fetch.sh iso386` fetches it, and
`zig build isoroot -- .local/9front/9front-<release>.386.iso .local/9front/root386`
([tools/isoroot.zig](tools/isoroot.zig)) unpacks it in about 20 seconds.
The tree works with `--dir` as it is: isoroot adds the kernel's mount points and
the empty `/mnt` and `/n` directories an install has (so the plumber, factotum,
and webfs can mount), and leaves out the installer's `dist/`.
That's how the [pages workflow](.github/workflows/pages.yml) builds the demo
and publishes it with the project page, [site/index.html](site/index.html),
to GitHub Pages. It runs on pushes to main that change `site/`, `src/web/`,
or `tests/web/`, and by hand (`gh workflow run pages`) for anything else.
`scripts/fetch.sh isoamd64` fetches the amd64 ISO the same way, which is how
the [ci workflow](.github/workflows/ci.yml) gets the amd64 root for the
integration cases on KVM.

The demo page runs over a WebSocket 9P server with `?root=ws://…/9p`. The
integration run's WebSocket cases serve their roots from a native h9 on
the emulator.

The web host's only network is WebSockets: `#I` is masked, and `--net`
(outbound by default) binds `/net/ws` alone at `/net`. The browser does the
handshake, TLS, and proxies, so a `--url`'s `header=` and `ca=`, and `header` in
`ctl` are errors there, and `--net-allow` can't check what a name resolves
to. A page embeds a machine with
`createMachine({ root, memory, policy, terminal })` from `h9-web.js`, where
`root` is a root archive's URL or a `ws://` or `wss://` URL; each machine
runs in its own Worker.

## Tests

The demos and the integration tests use the root tree from
`zig build mkroot`, or `-Droot=DIR`. Without a tree, the integration tests
skip and only the hello demos run. Each case is tagged with the proposal it
proves (`test "echo [baseline]"`); cases for a proposal that isn't implemented
yet skip in `zig build integration` unless `-Dpending` is given, and
`zig build proposal -Dp=<slug>` runs one proposal's cases whatever its
status. Interactive cases run h9 on a terminal the test creates
([tests/term.zig](tests/term.zig): a pty, or ConPTY on Windows), so they need
no human and no `ssh -t`.

[tests/engines.zig](tests/engines.zig) runs small programs on every engine
built in and checks that each gives the same output and syscall trace.
[tests/integration.zig](tests/integration.zig) runs real binaries from the
root tree through `h9` itself, checking output and exit codes.
`zig build integration` splits the cases four ways by a hash of their names
and runs the four parts at once, since the cases mostly wait on h9,
terminals, and sockets; `-Dshards=N` picks another count, and `-Dshards=1`
runs them in one process. `zig build test` likewise runs
[src/engine/hcpu/hcpu.zig](src/engine/hcpu/hcpu.zig)'s tests as four binaries split by name.
`zig build install-tests` installs both, built for `-Dtarget`, as
`zig-out/bin/engine-tests` and `zig-out/bin/integration-tests`, to run in a
VM.

`zig build` also writes the test binaries `zig-out/fixtures/hello` (arm64) and
`zig-out/fixtures/hello-amd64`. They're hand-assembled a.outs (see
[tests/fixtures/hello.zig](tests/fixtures/hello.zig)) because Zig no longer
links Plan 9 a.out.

The Go programs in [tests/fixtures/go](tests/fixtures/go) are built by
`zig build go-fixtures` into `zig-out/fixtures/go`, as
`GOOS=plan9 GOARCH=amd64` with `GOTOOLCHAIN=go$GO_VERSION` from
[scripts/pins.sh](scripts/pins.sh), so any installed Go fetches the same
toolchain. `zig build integration` builds them when `go` is on `PATH`, and
their cases run on sud when it's in the list, else on the emulator;
without Go they skip. They don't need the root tree.
`zig build go-stdtest` runs Go's own tests for `time`,
`syscall`, `os`, and `runtime` on the emulator and prints pass, skip, and
fail counts for each ([scripts/go-stdtest.sh](scripts/go-stdtest.sh), with
the tests it skips in `scripts/go-stdtest.skip`; `zig build go-stdtest -- os`
runs one package). It's for finding gaps, not a gate, and nothing depends on
it.

The [dotl](design/epoch-0/dotl.md) cases run against three 9P2000.L servers:
the one in [src/dotl/testserver.zig](src/dotl/testserver.zig), in
memory, which also speaks 9P2000.L.Z and can drop connections on cue,
diod, and ZeroFS.
`scripts/fetch.sh diod` unpacks Ubuntu 24.04's diod package and the
libraries it links, at the hashes in [scripts/pins.sh](scripts/pins.sh),
into `.local/diod`, with `.local/bin/diod` to run it (x86\_64 Linux only,
and it needs `ar` and `zstd`); without it, diod's cases skip.
`scripts/fetch.sh zerofs` builds ZeroFS from source at the commit in
pins.sh with the host's cargo, which takes several minutes, into
`.local/bin/zerofs`; without it, ZeroFS's .L.Z cases skip, and CI
doesn't build it. "Linux v9fs
mounts --serve over a unix socket" runs only on Linux with the kernel's
9p, as root or with `sudo -n`, as in the `linux-kvm` VM.

### Namespace conformance

[tests/conformance/ns.rc](tests/conformance/ns.rc) is a script of
namespace operations (binds, unions, mounts, `..` across mounts, creates
in unions, `ORCLOSE`, and flush) that prints what each one showed, and
[tests/conformance/9front.out](tests/conformance/9front.out) is what it
printed on 9front's own kernel ([kernel-port](design/kernel-port.md)).
`zig build conformance` runs it on h9, on each engine `-Dengines` picks,
with the root tree (`-Droot`, and `-Darch`), and fails on any difference,
showing the first one; each engine's transcript is left in
`zig-out/conformance`. It skips without a root tree, and needs no QEMU.
When the script changes, record the transcript again on 9front:

```sh
zig build conformance -- --oracle   # boots the pinned arm64 image under QEMU (scripts/fetch.sh image), as mkroot does
```

It runs the script there with rc and writes `9front.out`
([tools/conformance.zig](tools/conformance.zig)). On TCG, with no
hypervisor for arm64, that takes well under a minute. A difference that
is a bug in h9's kernel is noted in kernel-port's Updates, not hidden by
changing the script.

### Workloads

The workloads in [tests/workloads](tests/workloads) run real programs on
real roots through `h9`, each timed: Python with its C modules, threads,
subprocesses, and pip, npm, git, sqlite3, jq, bash, and busybox's tools on a
Linux root, and 9front's compilers and `mk` building awk and rc from
`/sys/src`. A case is a short script, `NAME.sh` for `/bin/sh` on the Linux
root or `NAME.rc` for rc on the 9front root, with `# expect:`,
`# status:`, `# timeout:`, and `# known:` lines at the top
([scripts/workloads.sh](scripts/workloads.sh) says what each does).
`scripts/fetch.sh workloads` makes the Linux root,
`.local/linux/workloads-amd64`, from the amd64 Alpine root and the
packages pinned in `scripts/pins.sh`, and the 9front root is
`.local/9front/rootamd64` (from `scripts/fetch.sh isoamd64` and
`zig build isoroot`, as above) or `.local/9front/root`:

```sh
zig build workloads -Darch=amd64 -Dengines=sud
zig build workloads -Darch=amd64 -Dengines=sud -- python git   # cases by name
```

The cases run in parallel and print a table of results and times. Each
case's stdout and stderr are in `zig-out/workloads`. A case with a `known`
line is expected to fail, and the run fails when it passes, so the line
gets removed. The [workloads workflow](.github/workflows/workloads.yml)
runs them every two days on main, unless nothing they depend on has
changed since the last run that passed, and by hand on any branch.

### Test VMs

[scripts/lima](scripts/lima/README.md) has Lima VMs (arm64 Linux, macOS, and
Windows, plus emulated x86\_64 Linux) for testing the hcpu engine on hosts
without a usable hypervisor:

```sh
zig build -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm up linux
scripts/lima/vm push linux zig-out/linux/bin/h9 zig-out/fixtures/hello
scripts/lima/vm shell linux ./h9/h9 --engine hcpu ./h9/hello
scripts/lima/vm push-root linux             # the root tree, into ~/h9/root

zig build install install-tests -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm test linux                  # engine and integration tests on the emulator
```

## Releases

Each GitHub release has these binaries, built by
`scripts/release.sh [version]` into `dist/<version>/` from a clean checkout:

| Asset | License | Contents |
| --- | --- | --- |
| `h9-<version>-<target>` | MIT | `h9`, with the hypervisor engines and hcpu, for macOS arm64, Linux arm64 and x86_64 (musl, static), and Windows arm64 and x86_64 |
| `h9-web-<version>.tar.gz` | MIT | the web host: `h9.wasm`, `h9-web.js`, `h9-node`, the demo page, and its root archive |
| `h9ns-<version>.tar.gz` | MIT | the namespace kernel for the web: `h9ns.wasm`, `h9ns.js`, `h9ns-worker.js`, and the JS files they import |
| `h9ns-<version>-<target>.tar.gz` | MIT | the namespace kernel as a static library, `libh9ns.a` and `h9ns.h`, for the targets above but Windows |
| `libh9-<version>-<target>` | MIT | h9's C ABI as a shared library (`libh9.so`, `libh9.dylib`, or `h9.dll`) and `h9.h`, for Linux amd64 and arm64 (glibc), macOS arm64, and Windows amd64; go-h9 fetches these |
| `SHA256SUMS` | | checksums |

Releases used to include `h9-emu`, a GPLv2 build of h9 for hosts without
a usable hypervisor. hcpu replaced it, so it isn't released anymore, and
every release asset is MIT. The script builds every binary from an unpacked `git archive` of
the commit, so what ships is exactly what was committed, and runs on macOS,
which cross-compiles the other targets.

Release builds report the release's version in `--version` and `--check`;
development builds report `git describe` (`-Dversion=V` overrides it).

## Layout

| Path | Contents |
| --- | --- |
| `src/main.zig`, `src/cli.zig`, `src/stdin.zig`, `src/hostsig.zig`, `src/tools.zig` | CLI: entry point, flag parsing with no I/O, the host stdin reader (cancellable, for the console's reader thread), Ctrl-C, hangup, and raw mode on the host terminal, and `--check`/`--version` |
| `src/gfx.zig`, `src/kern/gfx*.c`, `src/kern/nogfx.c` | `--gfx`: the window claim and `h9.gfx.main`, the kernel glue around drawterm's GUI backends (lazy `#i`, the kbdfs `/dev/kbd`, `/dev/screen`, `/dev/mousein`, `/dev/kbdin`, the clipboard, and the choice of screen), the headless screen, and the stubs for builds without graphics |
| `src/root.zig` | library root; [docs/embedding.md](docs/embedding.md) explains using it |
| `docs/` | guides that go further than the manual; `docs/embedding/embed.zig` is the embedding guide's example program |
| `src/machine.zig` | one machine: builds its namespace, runs a process, and serves its syscalls |
| `src/consin.zig` | a machine run's console input: the reader thread a guest's console read waits on, so notes can interrupt it |
| `src/policy.zig` | the sandbox policy: profiles, the compiled plan, `--print`, and the access rules devfs checks |
| `src/kern.zig`, `src/kern/` | the Zig/C seam into drawterm's kern; the parts of drawterm's kern ported to Zig ([kernel-port](design/kernel-port.md): `port.zig`, with queues and blocks in `qio.zig`, locks and sleep in `sync.zig`, the device helpers and switch in `dev.zig`, which calls C devices through `devshim.c`, the mount table in `pgrp.zig`, channels and `namec` in `chan.zig`, the file system calls in `sysfile.zig`, the 9P client in `devmnt.zig`, and pipes and the root device in `dev/`); boot and spawn (`glue.c`), process records and notes (`proc.c`), our device table, the machine console `#y`, devenv, and devproc ported from 9front, the copy-on-write overlay device `#O` (`devoverlay.c`), h9's guest commands `#H` (`devhtools.c`), and the devfs policy hooks (`fscheck.c`) |
| `src/guest/` | h9's own guest commands (rc scripts), as the guest sees them under `#H`; embedded by the build through `tools/guesttree.zig`. |
| `src/abi/plan9/syscall.zig`, `src/guestmem.zig` | the 9front syscall table, and checked access to guest memory |
| `src/abi/plan9/loader.zig` | loads an a.out into an address space, builds the stack and Tos |
| `src/abi/plan9/aout.zig` | a.out parser and arch layouts |
| `src/engine.zig`, `src/engine/` | the engine interface and engines (HVF, KVM, WHP, sud, and hcpu, h9's own CPUs, which the web host uses too), with the guest-physical allocator and page tables the hypervisor engines share |
| `src/engine/hcpu/hcpu.zig`, `src/engine/hcpu/jit/`, `src/engine/hcpu/interp/` | h9's own CPUs for the emulator (hcpu): the JIT's IR and its reference evaluator, the runtime ABI, the emitters (arm64, wasm), the front ends (`a64/`), and the interpreters and software TLB the two tiers share. `src/engine/hcpu/jit/README.md` has the contracts |
| `src/web.zig`, `src/web/` | the web host: coroutines on JSPI, its `std.Io` and console, the JS host (`h9-web.js`, `h9-node`, `worker.js`, `wasi-mem.js`, and `statictree.js` for static dotfs trees) and the demo page |
| `src/nskernel.zig`, `src/nskernel/`, `src/kern/devns.c`, `src/kern/nstab.c` | the namespace kernel: its Zig root (ctl lines, dials, serving, the native API), `h9ns.h`, the `#N` device, and its device table and stubs; `src/web/h9ns.js` and `h9ns-worker.js` are its JS host |
| `src/capi.zig`, `src/capi/` | libh9: machines behind a C ABI (`h9.h`), configured with the CLI's flags through `src/cli.zig`; `docs/embedding/hello.c` uses it |
| `src/arch/` | per-architecture Ureg/ABI and the guest shims |
| `third_party/drawterm` | vendored drawterm (git subtree; kern and libraries). Local changes: the sandbox hooks in `kern/devfs-posix.c` and `kern/devfs-win32.c` |
| `tests/engines.zig` | engine conformance tests |
| `tests/integration.zig` | real 9front binaries through the h9 CLI |
| `tests/term.zig` | a pty (ConPTY on Windows) for the interactive integration cases |
| `tests/fixtures` | test programs and binary generators; `segattach/` holds the arm64 programs for the segattach engine cases and `gfx/` those for the `[gfx]` cases, assembled at build time |
| `tests/web/` | the web host's Playwright check, and the namespace kernel's Node cases with a small 9P2000 client and server (`ninep.mjs`) |
| `tests/nskernel.zig`, `tests/ninep.zig` | the namespace kernel's native cases, and their 9P2000 client |
| `tests/jit/` | the wasm emitter's checks: a runtime module standing in for h9.wasm, a random region generator, the suite (`suite.mjs`) and its Node and Chromium drivers, and `bench.mjs`, which times installs and tier-up in V8 |
| `tools/mkroot.zig` | `zig build mkroot`: builds the 9front root tree from the pinned image |
| `scripts/release.sh` | builds the release assets (`h9` and `h9-web`) into `dist/` |
| `.local/` | gitignored: tools, caches, upstream clones, 9front images, prebuilt Unicorn (the lockstep oracle), test VMs |
