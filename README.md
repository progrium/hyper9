# h9 - Hyper9

Run native Plan 9 (9front) executables directly on host hypervisors. See
[MANUAL.md](MANUAL.md) for using h9, and [DESIGN.md](DESIGN.md) for how it works.

## Status

h9 is under active development and isn't ready for general use yet. Work is
planned as proposals under [design/](design/README.md), each with its status
and the proposals it depends on; the [baseline](design/0000-baseline.md) is
what's built so far. [design/STATUS.md](design/STATUS.md) has the table of
proposals and their dependency graph, and `zig build design -- ready` lists
what can be started now.

## Setup (macOS arm64)

Requires Zig 0.16.x and Xcode (for the macOS SDK and `codesign`).

```sh
. scripts/env.sh               # Zig cache and tools live in .local/ (gitignored); puts zig-out/bin (h9) on PATH
./scripts/fetch.sh             # reference sources (9front at the pinned release), 9front arm64 image, prebuilt and patched-source Unicorn, v86 into .local/ (or name parts: fetch.sh v86 iso386)
zig build mkroot               # extracts the 9front root tree into .local/9front/root (~1 min, ~250 MB)
```

`zig build mkroot` ([tools/mkroot.zig](tools/mkroot.zig)) boots the pinned
image headless in QEMU (`brew install qemu`), tars the file system out onto a
scratch disk, and unpacks it into
`.local/9front/root-<release>`, with `.local/9front/root` linked to it. The
image itself isn't modified. It's the host-tree root h9 serves as `/`.
Boot kernels, `/sys/doc`, and `/sys/src` are left out; pass `--src` to keep
`/sys/src`, which [self-hosting](design/0010-self-host.md) needs. Options go
after `--`: `zig build mkroot -- --src`.
The tree has the host's architecture's binaries unless `--arch` names
others (`--arch arm64`, `--arch 386,amd64`). The image's binaries are arm64;
`/386` and `/amd64` are filled by cross-compiling `/sys/src` inside h9
(`objtype=386 mk install`), which takes a built `zig-out/bin/h9` (or `$H9`).
Each architecture takes a few minutes on an arm64 hypervisor, but about an
hour on the emulator, which x86\_64 hosts need because the compilers are
arm64. On an existing tree it builds the host's
architecture only if it's missing, and what `--arch` names again.
`zig build integration -Darch=386` then runs the integration cases with the
386 binaries on the emulator.

Pinned upstream versions are in [scripts/pins.sh](scripts/pins.sh).

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

drawterm is committed under `third_party/drawterm` as a squashed git subtree,
so a fresh checkout builds without network access. To move to a new upstream
revision, bump `DRAWTERM_REV` and run `./scripts/vendor-drawterm.sh` on a
clean tree; it merges upstream into the subtree and keeps our local changes.

## Build

```sh
zig build          # builds and ad-hoc signs zig-out/bin/h9 with h9.entitlements
zig build test     # unit tests, and the backend tests on every backend built in
zig build kern     # compiles drawterm's kern and the libraries it uses
zig build embed    # builds docs/embedding/embed.zig, the embedding guide's example, as zig-out/bin/embed
zig build integration  # real 9front binaries from the root tree through the h9 CLI
zig build proposal -Dp=baseline  # one proposal's demos and integration cases (by slug or id)
zig build design -- check        # validate design/ and the test tags (also list, ready, graph, new, file)
zig build mkroot -- --src        # build the root tree from the pinned image (also --force, --arch arm64,386,amd64)
zig build -Dhost-cmd              # also build in host commands (#C, --host-cmd, hcmd), off by default (design/host-cmd.md)
zig build slim     # 9box, 9front's commands as one multi-call binary, and a slim root around it in .local/9front/slim-<release>-<arch>
zig build web      # the browser host into zig-out/web (h9.wasm, h9-web.js, v86.wasm, h9-node, the demo page)
zig build integration -Dweb   # the integration cases through h9-node on v86 (Node 24 or later)
zig build web-test # the demo page in Chromium, with Playwright
zig build clean    # removes zig-out and .zig-cache (not the fetched .local tree)
```

The demos and the integration tests use the root tree from
`zig build mkroot`, or `-Droot=DIR`. Without a tree, the integration tests
skip and only the hello demos run. Each case is tagged with the proposal it
proves (`test "echo [baseline]"`); cases for a proposal that isn't implemented
yet skip in `zig build integration` and `zig build test` unless `-Dpending` is
given, and `zig build proposal -Dp=<slug or id>` runs one proposal's cases
whatever its status.
Interactive cases run h9 on a terminal the test creates
([tests/term.zig](tests/term.zig): a pty, or ConPTY on Windows), so they need
no human and no `ssh -t`.

`zig build slim` builds [9box](design/0064-multicall.md) inside the h9 it just
built, against the root tree: 9front's own commands, compiled from the pinned
source with their globals renamed so they share one link, chosen by the name
they run as: the 42 commands basic operation needs. `-Dslim-links=hard`
(hard links to `9box`, the default) or `stub`
(`#!/bin/9box -!` files, for trees without hard links), and `-Darch`;
`-Dslim-links=copy` builds nothing and makes `slim-copy-*` with the same
commands copied from the root, to measure the box against
([tests/fixtures/multicall/execloop.rc](tests/fixtures/multicall/execloop.rc)). It
needs `/sys/src`, from `zig build mkroot -- --src` or the checkout `fetch.sh` makes,
and takes a few minutes on the emulator. The tree is `9box`, its links,
`rcmain`, and the mount points, and runs with
`h9 --root .local/9front/slim-11952-arm64`. The `[64]` cases use it,
and skip without it.

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
from source. kern
builds for Windows with drawterm's win32 files, so h9.exe runs programs on
the emulator, and host paths are `/C:/...` in `#U`. On Windows x86\_64,
h9.exe also has the WHP backend ([whp](design/0017-whp.md), a draft): it
needs the Windows Hypervisor Platform feature (Settings >
Optional features, or `DISM /Online /Enable-Feature
/FeatureName:HypervisorPlatform`, then restart), and loads
`WinHvPlatform.dll` only when it's used, so h9.exe still starts, and `auto`
falls back to the emulator, without it.

`-Dgfx` picks the GUI backend for `--gfx` ([gfx](design/0015-gfx.md)):
drawterm's Cocoa on macOS and Win32 on Windows by default, `none` on Linux.
`-Dgfx=x11` builds the X11 backend for Linux, which links the host's libX11
(and needs the libXt headers), so it builds natively against glibc, not for
a musl target. `-Dgfx=none` leaves graphics out; `-Dgfx=headless` is a screen
in memory, which the backend tests use whatever `-Dgfx` is.

### Browser host

`zig build web` builds h9 for wasm32-wasi
([browser-host](design/0012-browser-host.md)). It runs 9front's 386 binaries
on v86, needs JavaScript Promise Integration (Chrome 137 or later, Node 24 or
later), and takes `v86.wasm` from `scripts/fetch.sh`. With a 386 root tree
(`scripts/mkroot.py --arch 386`, linked or copied as `.local/9front/root386`,
or `-Dweb-root=DIR`) it also packs the demo page's root archive, `root.h9a`,
from the paths in `src/web/root.list`.

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

## Releases

Each GitHub release has two sets of binaries, built by
`scripts/release.sh [version]` into `dist/<version>/` from a clean checkout:

| Asset | License | Contents |
| --- | --- | --- |
| `h9-<version>-<target>` | MIT | `h9` with the hypervisor backends only (macOS arm64 for now) |
| `h9-emu-<version>-<target>` | GPLv2 | `h9-emu`: h9 built with `-Demu=unicorn`, for macOS arm64, Linux arm64 and x86_64 (musl, static), and Windows arm64 and x86_64 |
| `h9-emu-<version>-source.tar.gz` | GPLv2 and MIT | complete corresponding source for `h9-emu`: the h9 tree plus Unicorn's patched source in `.local/src/unicorn` |
| `h9-web-<version>.tar.gz` | MIT and BSD-2 | the browser host: `h9.wasm`, `h9-web.js`, `h9-node`, `v86.wasm` (BSD-2, `LICENSE.v86`), the demo page, and its root archive |
| `SHA256SUMS` | | checksums |

`h9-emu` takes the same flags as `h9` and runs on hosts without a usable
hypervisor. It links Unicorn Engine, so the binary as a whole is GPLv2, with
`COPYING`, `NOTICE`, and the MIT notices in each archive; see [LICENSE](LICENSE).
The script builds every binary from the unpacked source tarball, with Unicorn
from source (`-Dunicorn=source`), so the tarball is exactly what was built. It
needs `scripts/fetch.sh` to have been run and runs on macOS, which
cross-compiles the other targets.

## Run

```sh
zig-out/bin/h9 [h9-flags] [--] program [args...]
zig-out/bin/h9 [h9-flags] --rc ['command' [args...]]   # alone: a login rc, the root's default command
zig-out/bin/h9 --version                  # version, pinned 9front and drawterm, backends and gfx built in
zig-out/bin/h9 [--backend B] [--root DIR|DIAL|SOCKET|URL] --check
zig-out/bin/h9 --help                     # or -h alone

zig-out/bin/h9 /bin/cat /lib/namespace    # a baseline demo
zig-out/bin/h9 ls -l /bin/cat             # bare names search $path: . and /bin
zig-out/bin/h9 ./hello                    # ./ and ../ are host paths
zig-out/bin/h9 --root 'tcp!localhost!5640' ls /   # a 9P server as the root
zig-out/bin/h9 --gfx rio                  # rio in a host window
```

A program starting with `./` or `../` is read from the host. Anything else is
a guest path or name in the machine's namespace: `/` is the root tree
(`--root`, else `$H9ROOT`, else `.local/9front/root` next to a development
build; with none found, a guest program is an error, exit 125), `/bin` is `/$cputype/bin` (`/arm64/bin` on arm64) plus `/rc/bin`, and the host cwd (or `--cwd`)
is at `/mnt/term/cwd` and is the guest's cwd. The host environment isn't
imported: the guest gets `user`, `home`, `cputype`, `objtype`, `sysname`,
`service`, `path`, `timezone`, and `NPROC` (the vCPUs the machine can run
at once: `--cpus`, else the host's CPU count), plus any `--env`, which
overrides them. Exit codes: 0 for an empty
`exits` string; the number itself for an `exits` string that's a decimal
number from 1 to 255 (no sign, leading zero, or spaces), so rc's `exit 3` and
Go's `os.Exit(3)` exit 3; and 1 for any other string, which is printed to
stderr. A program killed by a note exits as a host shell reports a signal
([exit-status](design/0033-exit-status.md)): 128 plus the host's signal number for
a note APE maps to a signal, so Ctrl-C exits 130 and a closed pipe 141, both
silently; 139 for a fault; 124 for `--timeout`; 128 plus the host signal
(130, 129, or 143) when a second Ctrl-C, SIGHUP, or SIGTERM tears the machine
down; and 1, with the note printed, for any other note. h9's own failures
are 2 for a usage error, 125 when h9 itself fails, 126 when the program isn't
a runnable a.out and 127 when it isn't found, and h9 prints a message for
each, so a guest that exits with one of those numbers can still be told
apart.

Go's `GOOS=plan9 GOARCH=amd64` binaries run on the emulator (`--backend emu`,
or `--arch amd64` with h9-emu): goroutines on several processes, timers,
`os/exec`, `net/http`, and `os/signal`. A Go program reserves several hundred MB
of memory at start, so one that uses `os/exec` needs `--memory 4G`.

`--check` creates a VM on each backend built in (or just `--backend`'s) and
runs a test program on it, which on macOS also checks the hypervisor
entitlement. It reports the hypervisor's vCPU limit, then runs `/bin/echo` from the root
tree. It exits 0 if h9 can run programs from the root, and 125 otherwise.
Release builds report the release's version; development builds report `git
describe` (`-Dversion=V` overrides it).

`--root` also takes a 9P server ([9p-roots](design/0013-9p-roots.md)): a
dial string, `tcp!host!port` (`tcp!host` means port 564) or `unix!path`, or
the path of a unix socket. h9 connects before the program runs, posts the
connection in the guest's `/srv` as `root`, and mounts it at `/`; everything
else is bound over it as over a host tree, and programs run from the server.
`--root-spec NAME` sets the attach name and `--root-user NAME` the attach
uname (the machine's user by default). The server must not want
authentication: u9fs with `-a none`, or `exportfs` behind `aux/listen1 -t`,
such as a second h9 serving a root tree read-only:

```sh
h9 --net=enable aux/listen1 -t 'tcp!127.0.0.1!5640' /bin/exportfs -R -r / &
h9 --root 'tcp!127.0.0.1!5640' ls /
```

Writes to a 9P root go to its server, which decides what's writable, so
`--write=none` with one is a usage error. A failed connection or attach is
exit 125. Unix socket roots need a POSIX host. The connection is plain 9P,
so keep a TCP root on a trusted network.

A 9P server behind a WebSocket works too
([websocket-9p](design/0021-websocket-9p.md)): `--root ws://host/path` or
`wss://host/path`. h9 makes the connection on the host (TCP, TLS for `wss`,
the handshake offering the `9p` subprotocol), then mounts it as it mounts any
9P root. `--root-header 'Name: value'` (repeatable) adds a handshake header,
such as `Authorization: Bearer …`, and `--root-header @FILE` reads one header
per line from a file, so a token stays out of `ps`. `wss` trusts the host's CA
bundle; `--root-ca FILE` trusts a PEM file instead. `HTTPS_PROXY`,
`HTTP_PROXY`, and `NO_PROXY` are honored with `CONNECT`, with credentials from
the proxy URL. After 30 seconds without a frame h9 pings the server, and a
server silent for 30 more is a hangup. The scheme can be left off
([schemeless-roots](design/0076-schemeless-roots.md)): a `--root` or `$H9ROOT`
that isn't an existing path and looks like `host[:port][/path]` is read as
`wss://host/path`, or `ws://` for `localhost`, `127.x.x.x`, and `[::1]`, so
`--root fs.example.com/9p` means `wss://fs.example.com/9p`. The host needs a
dot, brackets, or a port, or must be `localhost`; anything starting with `.`,
`/`, or `~` stays a path. A namespace file can mount a URL too:
`mount -c 'wss://fs.example/9p' /n/fs`. `--print` shows the URL with its query
elided and header values as `…`. A demo, with the 9P server above and the
relay from the tests in front of it:

```sh
zig build wsrelay -- 8080 5640 &
h9 --root localhost:8080/9p ls /   # the same as ws://localhost:8080/9p
```

The guest can open WebSockets as well: `/net/ws` is laid out like
`/net/tcp`, and follows `--net` and `--net-allow` as a TCP dial to the URL's
host and port would. Mounting a 9P server from rc:

```rc
{ n=`{read}
  echo connect wss://fs.example/9p 9p >/net/ws/$n/ctl
  mount -c /net/ws/$n/data /n/fs } <>/net/ws/clone
```

A conversation's `data` file carries binary messages as a byte stream, and its
`text` file carries text messages one per read and write, for any WebSocket
service. Guest connections don't use the host's proxies.

Flags: `--backend auto|hvf|kvm|whp|emu`, `--arch arm64|amd64|386`, `--root DIR|DIAL|SOCKET|URL`, `--root-spec NAME`, `--root-user NAME`, `--root-header 'NAME: VALUE'|@FILE`, `--root-ca FILE`, `--root-contained`, `--cwd DIR`, `--env
name=value` (repeatable), `--rc 'cmd'`, `--ns FILE`, `--trace[=FILE]`,
`--dump-on-fault`, and the sandbox flags below. `--rc` runs `/bin/rc -c`.
As the last argument, `--rc` alone runs a login rc, which sources the root's
`/rc/lib/rcmain.local`, so a root sets its default command there.
`--ns FILE` replays a namespace file in newns syntax (`bind`, `mount`,
`unmount`, `cd`, `clear`) before the program runs; it's a guest path, so a
relative one is in the guest's cwd, and `--print`'s namespace section can be
saved and replayed as is. A `bind -c '#O' PATH` line in it puts a fresh
copy-on-write overlay over whatever PATH is at that point in the replay.

`--backend auto` (the default) uses the host hypervisor (HVF on macOS, KVM on
Linux, WHP on Windows x86\_64) and otherwise falls back to the emulator with a warning that says why.
The emulator also runs amd64 binaries on arm64 hosts, for testing, and 386
binaries on every host; HVF runs arm64 only, KVM the host's architecture, and
WHP amd64 only.
`--arch` picks the architecture: a host program otherwise runs as its header
says, and a guest one as the host's, so `h9 --arch 386 /bin/echo hi` runs
`/386/bin/echo` from a root that has it.

Syscalls go through drawterm's kern: open, create, close, dup, pread, pwrite,
seek, stat, fstat, wstat, fwstat, fd2path, bind, mount, unmount, fauth, chdir,
remove, errstr, brk_,
sleep, notify, noted, exits, and for process trees rfork, exec (including `#!`
scripts), await, and pipe, and the segment calls segattach, segdetach,
segbrk, segfree, and segflush for `shared` and `memory` segments (so `seg`
works; named `#g` segments and device memory aren't served), and rendezvous,
semacquire, tsemacquire, and semrelease, so contended `qlock`s and libthread
park as on 9front; `/fd` is devdup. Notes are delivered as on 9front:
a handler set with notify gets the note and a saved Ureg on its stack, and a
process without one dies with the note as its status, so a write to a closed
pipe ends the writer with `sys: write on closed pipe pc=...`, and a fault or
bad syscall can be caught.

`/proc` lists the machine's own processes by their machine-local pids, as
on 9front, so `ps` and `kill` work: `kill sleep | rc` posts a `kill` note
to each sleep. Each process has `args`, `ctl`, `fd`, `fpregs`, `mem`,
`note`, `noteid`, `notepg`, `ns`, `ppid`, `regs`, `segment`, `status`, `text`,
and `wait`; the CPU times in `status` read 0 for now, and `ns` shows the host
paths of bound host trees. `ctl` takes `kill`, `close`, `closefiles`, and
acid's `stop`, `start`, `waitstop`, `startstop`, `hang`, and `nohang`, so acid
debugs a live process (`h9 --rc 'sleep 5 & sleep 1; acid $apid'`, then
`stk()`), and a `BRK` or `INT3` posts `sys: breakpoint`
([self-host](design/0010-self-host.md)).

**Building from source.** With `/sys/src` in the root (`zig build mkroot -- --src`), or
bound in with `--readable`, the compilers, linkers, and mk run as on 9front:

```sh
cp "$H9ROOT/sys/src/cmd/ls.c" . && h9 --rc '7c ls.c && 7l -o 7.ls ls.7 && ./7.ls'   # build in the cwd
cp -cR "$H9ROOT" /tmp/root     # a disposable copy (an APFS clone on macOS, about a second)
h9 --root /tmp/root --writable /tmp/root --rc 'cd /sys/src && mk install'   # rebuild the userland in place
h9 --root /tmp/root --writable /tmp/root --rc 'cd /sys/src && objtype=amd64 mk libs'  # once, before cross-building for amd64
```

Without `--writable`, `mk install` writes to the run's overlay and is
discarded at exit (or fails with "permission denied" under `--write scope`).

`/srv` is the machine's own service registry (`#s`, from 9front), so guest
file servers post themselves and other processes mount them, with or
without `fauth`: `h9 --rc 'ramfs -S tmp && mkdir /tmp/n && mount -c
/srv/tmp /tmp/n && touch /tmp/n/a && ls /tmp/n'`. ramfs, srvfs, exportfs,
factotum, and plumber run. Machines in one host process can't see each
other's `/srv`, and what's posted is closed when the machine ends.

h9's own commands, the small rc scripts that wrap h9's devices (such as
`wsmount` for 9P over WebSocket, and `hcmd`, which runs a host command
through `#C` under `--host-cmd` in builds with `-Dhost-cmd`), are built into the h9 binary from
[src/guest/](src/guest) and served read-only by `#H`. The namespace binds
`#H/bin` after the root's `/bin`, so they're on the path, and a root command
of the same name wins. `--no-guest-tools` leaves the bind out and masks
`#H`. The root tree itself is never changed. Only rc scripts and data go in
`src/guest/`: the build fails on an executable that doesn't start with
`#!/bin/rc`. Debug builds also serve the test-only scripts in
`tests/fixtures/guest/` for the integration cases; release builds don't
(`-Dguest-test` overrides it).

At the terminal, Ctrl-C posts `interrupt` to the foreground note group (rc
abandons the command and prompts again); a second Ctrl-C within a second
stops the machine. Closing the terminal or SIGTERM posts `hangup` to every
process, and `--timeout` does the same at its deadline; the machine is torn
down 2 s later if it hasn't exited. A program that writes `rawon` to
`/dev/consctl` puts the host terminal in raw mode until `rawoff`, its last
close of consctl, or the end of the run.

Each process has its own kernel
thread and normally its own vCPU. HVF allows 64 vCPUs, so past 56 processes
the rest share a pool of 8 vCPUs, which costs a thread handoff per syscall.
`--trace` prints one line per syscall
to stderr, or to a file with `--trace=FILE`. `--dump-on-fault` prints the
registers and the symbolized PC when the guest faults.

### Graphics

`--gfx` gives the machine one host window, drawn by drawterm's own GUI code,
and binds `/dev/draw`, `/dev/mouse`, `/dev/cursor`, and `/dev/kbd` from it, with
`/dev/snarf` as the host clipboard. rio and acme run in it; the console stays
the host terminal. `--gfx=noclip` keeps `/dev/snarf` inside h9 instead of the
host clipboard, and `--gfx-scale N` sets the scale on macOS (drawterm's `-x`).
Closing the window posts `hangup` to the machine. Only one machine in a
process has the window. Without `--gfx`, `#i`, `#m`, and `#b` are masked. A
build without a GUI backend, or with no display (`$DISPLAY` unset for X11),
exits 125 on `--gfx`; `--check` reports a `gfx` line. rio needs `/mnt/temp` in
the root tree, which `zig build mkroot` makes (and adds to an existing tree).

```sh
h9 --gfx rio
h9 --gfx rio -i 'window acme'
```

### Sandbox

> **Warning!** This is a ~~stable~~ in-development research prototype, but it has not been through any formal security audits or any other verification. Such a review would be essential before trusting h9 to handle malicious code in the wild. USE AT YOUR OWN RISK!

By default the guest sees the root tree under a copy-on-write overlay
([overlay](design/0011-overlay.md)), the host cwd read-write at
`/mnt/term/cwd`, a private `/tmp` in memory, and nothing else of the host.
Writes to the root succeed, live in memory (counted against `--memory`)
and are gone when the machine ends; the root tree on the host is never
written. `$home` exists, made in the overlay when the root has no
`/usr/$user`. When a run on a terminal changed the root outside `$home`,
h9 says which top-level directories it discarded. `--writable "$H9ROOT"`
writes the root tree instead, and `--write=scope` makes the root
read-only. `--write=ephemeral` makes every writable path a copy-on-write
overlay as well, so nothing reaches the host. `#U` and `#C` are masked, so the guest can't attach more of the host,
and symlinks are resolved before access is checked, so a link inside a bound
tree can't reach outside it. `--root-contained` resolves the root tree's
links inside it instead, as `chroot` would, for Linux roots and container
images whose links are absolute. See [DESIGN.md](DESIGN.md), "Sandbox policy".

```sh
h9 --profile=tight ls -l            # read-only cwd, no network, 10m timeout
h9 --sandbox ./work touch f         # tight, with only ./work bound, writable
h9 --profile=tight --writable ./out touch out/x
h9 --readable ~/src --read-deny ~/src/.env ls /mnt/term/$HOME/src
h9 --memory 256m --timeout 30s ls   # resource caps
h9 --pids 32 --cpus 2 --rc 'mk'     # at most 32 processes, 2 running at once
h9 --write=ephemeral --rc 'mk clean && mk'   # build in place; the host cwd is unchanged
h9 --print --profile=tight mk       # print the compiled plan and exit
h9 --rc 'echo hi > /lib/x && cat /lib/x'    # the root is writable; /lib/x is gone at exit
h9 --writable "$H9ROOT" --rc 'cd /sys/src/cmd && mk install'   # install into the root tree
h9 --write=scope mk                 # a read-only root, as a build check
h9 --net=enable aux/listen1 -t tcp!*!8080 /bin/cat     # servers need --net=enable
h9 --net-allow 'tcp!*.example.com!443' myclient        # egress only to these names
```

| Flag | Meaning |
| --- | --- |
| `--profile default\|tight` | Sandbox defaults; explicit flags override them |
| `--readable PATH`, `--writable PATH` | Bind a host path read-only or read-write; outside the root and cwd it appears at `/mnt/term/PATH` |
| `--read-deny PATH` | Hide a host path, even inside a bound tree |
| `--write none\|scope\|overlay\|ephemeral` | Deny all writes; allow them only in writable paths (`scope`, with a read-only root); `scope` plus a copy-on-write overlay over the root, discarded at exit (`overlay`, the default in both profiles); or make the root and the writable paths overlays in memory that are discarded at exit (`ephemeral`) |
| `--net disable\|outbound\|enable` | Mask `#I`; allow clients but refuse `announce` (the default, except under `--profile=tight`, which disables); or allow servers too. Without `--net-allow`, connects to link-local addresses (169.254.0.0/16, fe80::/10) are refused |
| `--net-allow PATTERN` | Repeatable egress allowlist of dial strings, `proto!host!port`: `tcp!10.0.0.0/8!564`, `udp!10.0.0.53!53`, `tcp!*.example.com!443`. With any pattern, every connect and every `/net/cs` name lookup must match one |
| `--memory SIZE`, `--timeout DURATION` | Cap guest memory (`512m`); post `hangup` after a deadline (`30s`, `1m`) and stop the machine 2 s later |
| `--pids N`, `--cpus N` | Cap live processes (rfork fails with "no procs"); cap vCPUs running guest code at once |
| `--host-fs`, `--host-cmd` | Show the whole host read-only at `/mnt/term`; unmask devcmd (`-Dhost-cmd` builds only) |
| `--no-guest-tools` | Leave out `#H/bin`, h9's own commands, and mask `#H` |
| `--print`, `--strict` | Print the plan and exit; refuse (exit 2) capabilities this build can't enforce |

`zig build` also writes the test binaries `zig-out/fixtures/hello` (arm64) and
`zig-out/fixtures/hello-amd64`. They're hand-assembled a.outs (see
[tests/fixtures/hello.zig](tests/fixtures/hello.zig)) because Zig no longer
links Plan 9 a.out.

The Go programs in [tests/fixtures/go](tests/fixtures/go) are built by `zig
build go-fixtures` into `zig-out/fixtures/go`, as `GOOS=plan9 GOARCH=amd64`
with `GOTOOLCHAIN=go$GO_VERSION` from [scripts/pins.sh](scripts/pins.sh), so
any installed Go fetches the same toolchain. `zig build test` and `zig build
integration` build them when `go` is on `PATH` and h9 is built with
`-Demu=unicorn`, and their cases run on the emulator; without Go they skip.
They don't need the root tree. `zig build go-stdtest -Demu=unicorn` runs Go's
own tests for `time`, `syscall`, `os`, and `runtime` on the emulator and prints
pass, skip, and fail counts for each ([scripts/go-stdtest.sh](scripts/go-stdtest.sh),
with the tests it skips in `scripts/go-stdtest.skip`; `zig build go-stdtest --
os` runs one package). It's for finding gaps, not a gate, and nothing depends
on it.

[tests/backends.zig](tests/backends.zig) runs small programs on every backend
built in and checks that each gives the same output and syscall trace.
[tests/integration.zig](tests/integration.zig) runs real binaries from the
root tree through `h9` itself, checking output and exit codes. `zig build
install-tests` installs both, built for `-Dtarget`, as
`zig-out/bin/backend-tests` and `zig-out/bin/integration-tests`, to run in a
VM.

## Test VMs

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

## Layout

| Path | Contents |
| --- | --- |
| `src/main.zig`, `src/cli.zig`, `src/stdin.zig`, `src/hostsig.zig`, `src/tools.zig` | CLI: entry point, flag parsing with no I/O, the host stdin reader (cancellable, for the console's reader thread), Ctrl-C, hangup, and raw mode on the host terminal, and `--check`/`--version` |
| `src/gfx.zig`, `src/kern/gfx*.c`, `src/kern/nogfx.c` | `--gfx`: the window claim and `h9.gfx.main`, the kernel glue around drawterm's GUI backends (lazy `#i`, the kbdfs `/dev/kbd`, the clipboard), the headless test backend, and the stubs for builds without graphics |
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
| `src/vmm.zig`, `src/vmm/` | hypervisor interface and backends (HVF, KVM, WHP, emu on Unicorn, and v86 for the browser host), with the guest-physical allocator and page tables the hypervisor backends share |
| `src/web.zig`, `src/web/` | the browser host: coroutines on JSPI, its `std.Io` and console, the JS host (`h9-web.js`, `h9-node`, `worker.js`, `wasi-mem.js`) and the demo page |
| `src/arch/` | per-architecture Ureg/ABI and the guest shims |
| `third_party/drawterm` | vendored drawterm (git subtree; kern and libraries). Local changes: the sandbox hooks in `kern/devfs-posix.c` and `kern/devfs-win32.c` |
| `third_party/unicorn`, `build/unicorn.zig` | patches, per-host config headers, and the Zig build for Unicorn from source (GPLv2; source fetched, not vendored) |
| `tests/backends.zig` | backend conformance tests |
| `tests/integration.zig` | real 9front binaries through the h9 CLI |
| `tests/term.zig` | a pty (ConPTY on Windows) for the interactive integration cases |
| `tests/fixtures` | test programs and binary generators; `segattach/` holds the arm64 programs for the segattach backend cases and `gfx/` those for the `[gfx]` cases, assembled at build time |
| `tools/mkroot.zig` | `zig build mkroot`: builds the 9front root tree from the pinned image |
| `scripts/release.sh` | builds the release assets (`h9`, `h9-emu` and its source, `h9-web`) into `dist/` |
| `tests/web/` | the browser host's Playwright check and the v86 layout check |
| `.local/` | gitignored: tools, caches, upstream clones, 9front images, prebuilt Unicorn, test VMs |
