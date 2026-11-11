# Emulator performance

How much slower than native h9's own CPUs run real programs. It covers h86
(386 guests), ha64 (arm64 guests), and hx64 (amd64 guests), each on its JIT
(T1) and its interpreter (T0), natively and in WebAssembly, on an amd64 Linux
host and on an arm64 Mac.

In short, with the JIT:

| CPU | arm64 Mac | amd64 Linux host | in wasm (Mac) | in wasm (amd64) |
|---|---|---|---|---|
| ha64 | 5 to 10x | 17 to 32x | 28 to 55x | 29 to 48x |
| hx64 | 9 to 30x | 25 to 59x | 33 to 63x | 37 to 82x |
| h86 | 8 to 62x | 26 to 99x | 22 to 159x | 39 to 111x |

Each figure is how many times slower than the same program built for the
host and run natively. On the Mac, HVF runs the same arm64 programs at about
1.2x native. T0 is usually 3 to 12x slower than T1.

These are snapshots, measured in November 2026. ha64 and h86 were measured at
main `8067d1b` (amd64 host) and `14a24c9` (Mac), after the wasm JIT for ha64
(#164). hx64 was measured on the `hx64` branch at `e86efbc`. Rerun them
before relying on a number (see [Reproducing](#reproducing)).

## Contents

- [Method](#method)
- [arm64 host](#arm64-host)
- [amd64 host](#amd64-host)
- [What stands out](#what-stands-out)
- [Reproducing](#reproducing)

## Method

**Hosts.** The arm64 host is a MacBook Pro with an M3 Max and 96 GB, on
macOS 15.8.1. The amd64 host is a cloud VM with a 2.3 GHz Xeon, 4 cores,
15 GB, and no KVM, on Linux. Every h9 is a ReleaseFast build with
`-Demu=hcpu`.

**Workloads.** These are the five Linux programs from
[tools/workloads](../tools/workloads/README.md), on Alpine 3.22 roots built
for each guest architecture:

- `python3 -c 'print(sum(range(10**7)))'`
- `python3 bench.py`, the pure-Python benchmark: integer and float loops,
  calls, dicts, strings, and sorting
- SQLite's speedtest1, main test set, size 25, in memory, with its
  verification hash checked
- the sqlite3 shell, with a 200,000-row recursive query
- gowork, the Go program: crypto/sha256, encoding/json, and net/http on
  loopback

**Real program.** This is the baseline. It's the same program built for the
host and run natively, whatever the guest architecture. On the amd64 host,
that's the x86-64 Alpine root in a chroot. On the Mac, it's Homebrew's
Python 3.12.4, the system sqlite3 3.43.2, speedtest1 built with `zig cc -O2`
from the same SQLite 3.50.4 source, and gowork built for darwin/arm64.

**Columns.** Columns run from fastest to slowest:

- **HVF** is h9 on its hardware backend (Mac, arm64 programs only).
- **T1** and **T0** run `h9 --backend emu` with `H9_EMU_TIER=t1` or `t0`.
- **wasm T1** and **wasm T0** run the same tiers through `h9-node`, the
  browser host's build under Node (Node 25 on the amd64 host, Node 26 on the
  Mac).
- **v86** is [v86](https://github.com/copy/v86) 0.5.473 under the same Node,
  for 386 guests only. It boots Alpine 3.22's x86 virt kernel with the same
  root as an initramfs.

**Rows.** Each workload's first row is wall time, and the row under it is how
many times slower than the real program. Every run's output was checked
against the real program's, and all matched.

**Caveats.** h9's times are whole-process times, including h9-node's start.
v86's times run from a serial-console marker before each workload to one
after it, so they leave out its boot (9 s on the amd64 host and 4 s on the
Mac). That slightly favors v86 on the short workloads. Go can't run in wasm,
because its HTTP server can't listen on loopback in the wasm host. Those
cells are marked with a dash. Each figure is a single run; a repeat run on
the Mac agreed within 4%.

## arm64 host

### ha64 (arm64 guests)

| workload | real program | HVF | T1 | wasm T1 | T0 | wasm T0 |
|---|---|---|---|---|---|---|
| python sum(range(1e7)) | 0.13 s | 0.16 s | 1.17 s | 5.30 s | 10.44 s | 30.89 s |
|  | 1x | *1.2x* | *9.0x* | *41x* | *80x* | *238x* |
| python bench.py | 0.14 s | 0.17 s | 1.39 s | 7.71 s | 10.66 s | 28.64 s |
|  | 1x | *1.2x* | *9.9x* | *55x* | *76x* | *205x* |
| SQLite speedtest1 | 0.33 s | 0.38 s | 2.08 s | 9.92 s | 18.49 s | 47.93 s |
|  | 1x | *1.2x* | *6.3x* | *30x* | *56x* | *145x* |
| sqlite3 shell | 0.05 s | 0.04 s | 0.35 s | 1.42 s | 2.37 s | 7.03 s |
|  | 1x | *0.8x* | *7.0x* | *28x* | *47x* | *141x* |
| Go (sha256, json, http) | 0.10 s | 0.36 s | 0.55 s | — | 3.84 s | — |
|  | 1x | *3.6x* | *5.5x* |  | *38x* |  |

### hx64 (amd64 guests)

An arm64 Mac can't run amd64 code in hardware, so this table has no HVF
column.

| workload | real program | T1 | wasm T1 | T0 | wasm T0 |
|---|---|---|---|---|---|
| python sum(range(1e7)) | 0.13 s | 1.86 s | 7.09 s | 19.89 s | 46.91 s |
|  | 1x | *14x* | *55x* | *153x* | *361x* |
| python bench.py | 0.14 s | 2.39 s | 8.77 s | 21.12 s | 42.58 s |
|  | 1x | *17x* | *63x* | *151x* | *304x* |
| SQLite speedtest1 | 0.33 s | 3.07 s | 10.95 s | 37.70 s | 74.32 s |
|  | 1x | *9.3x* | *33x* | *114x* | *225x* |
| sqlite3 shell | 0.05 s | 0.46 s | 1.67 s | 4.75 s | 9.92 s |
|  | 1x | *9.2x* | *33x* | *95x* | *198x* |
| Go (sha256, json, http) | 0.10 s | 2.96 s | — | 51.22 s | — |
|  | 1x | *30x* |  | *512x* |  |

### h86 (386 guests)

The real program and HVF columns are the same arm64 programs as in the ha64
table, run again.

| workload | real program | HVF | T1 | wasm T1 | v86 | T0 | wasm T0 |
|---|---|---|---|---|---|---|---|
| python sum(range(1e7)) | 0.11 s | 0.15 s | 4.67 s | 17.46 s | 15.78 s | 62.28 s | 120.63 s |
|  | 1x | *1.4x* | *42x* | *159x* | *143x* | *566x* | *1097x* |
| python bench.py | 0.17 s | 0.18 s | 3.14 s | 11.19 s | 6.97 s | 27.76 s | 51.51 s |
|  | 1x | *1.1x* | *18x* | *66x* | *41x* | *163x* | *303x* |
| SQLite speedtest1 | 0.34 s | 0.38 s | 4.31 s | 12.96 s | 7.56 s | 45.46 s | 83.03 s |
|  | 1x | *1.1x* | *13x* | *38x* | *22x* | *134x* | *244x* |
| sqlite3 shell | 0.09 s | 0.05 s | 0.69 s | 1.96 s | 1.30 s | 5.90 s | 11.80 s |
|  | 1x | *0.6x* | *7.7x* | *22x* | *14x* | *66x* | *131x* |
| Go (sha256, json, http) | 0.10 s | 0.37 s | 6.22 s | — | 7.63 s | 39.68 s | — |
|  | 1x | *3.7x* | *62x* |  | *76x* | *397x* |  |

## amd64 host

### ha64 (arm64 guests)

| workload | real program | T1 | wasm T1 | T0 | wasm T0 |
|---|---|---|---|---|---|
| python sum(range(1e7)) | 0.18 s | 4.18 s | 6.65 s | 12.64 s | 26.29 s |
|  | 1x | *23x* | *37x* | *70x* | *146x* |
| python bench.py | 0.22 s | 5.79 s | 10.51 s | 17.03 s | 30.47 s |
|  | 1x | *26x* | *48x* | *77x* | *138x* |
| SQLite speedtest1 | 0.47 s | 8.08 s | 14.31 s | 30.72 s | 50.30 s |
|  | 1x | *17x* | *30x* | *65x* | *107x* |
| sqlite3 shell | 0.07 s | 1.37 s | 2.06 s | 5.04 s | 8.37 s |
|  | 1x | *20x* | *29x* | *72x* | *120x* |
| Go (sha256, json, http) | 0.13 s | 4.12 s | — | 7.00 s | — |
|  | 1x | *32x* |  | *54x* |  |

### hx64 (amd64 guests)

| workload | real program | T1 | wasm T1 | T0 | wasm T0 |
|---|---|---|---|---|---|
| python sum(range(1e7)) | 0.18 s | 7.28 s | 14.81 s | 26.88 s | 62.98 s |
|  | 1x | *40x* | *82x* | *149x* | *350x* |
| python bench.py | 0.22 s | 8.83 s | 15.16 s | 34.07 s | 70.08 s |
|  | 1x | *40x* | *69x* | *155x* | *319x* |
| SQLite speedtest1 | 0.47 s | 11.52 s | 20.51 s | 55.89 s | 120.88 s |
|  | 1x | *25x* | *44x* | *119x* | *257x* |
| sqlite3 shell | 0.07 s | 2.24 s | 2.56 s | 8.95 s | 17.11 s |
|  | 1x | *32x* | *37x* | *128x* | *244x* |
| Go (sha256, json, http) | 0.13 s | 7.63 s | — | 49.98 s | — |
|  | 1x | *59x* |  | *384x* |  |

### h86 (386 guests)

| workload | real program | T1 | wasm T1 | v86 | T0 | wasm T0 |
|---|---|---|---|---|---|---|
| python sum(range(1e7)) | 0.18 s | 12.99 s | 20.06 s | 26.85 s | 67.66 s | 157.37 s |
|  | 1x | *72x* | *111x* | *149x* | *376x* | *874x* |
| python bench.py | 0.23 s | 8.69 s | 15.29 s | 14.36 s | 35.08 s | 70.86 s |
|  | 1x | *38x* | *66x* | *62x* | *153x* | *308x* |
| SQLite speedtest1 | 0.47 s | 12.34 s | 19.62 s | 16.46 s | 55.64 s | 113.12 s |
|  | 1x | *26x* | *42x* | *35x* | *118x* | *241x* |
| sqlite3 shell | 0.07 s | 1.87 s | 2.74 s | 2.60 s | 9.03 s | 16.70 s |
|  | 1x | *27x* | *39x* | *37x* | *129x* | *239x* |
| Go (sha256, json, http) | 0.15 s | 14.87 s | — | 17.73 s | 45.14 s | — |
|  | 1x | *99x* |  | *118x* | *301x* |  |

## What stands out

- **ha64 is the fastest of the three everywhere**, including in wasm. hx64
  comes next, and its T1 beats h86's on every workload, by 1.3 to 2.5x on
  the Mac.
- **The amd64 host gives hx64 no advantage.** hx64 is slower than ha64 there,
  even though its guest and host share an architecture.
- **wasm costs more on the Mac.** Wasm T1 is 3 to 6x slower than T1 there,
  against 1.5 to 1.8x on the amd64 host. That's also why v86 does better
  against h86 on the Mac: up to 1.7x faster than h86's wasm T1 there, and
  about even with it on the amd64 host.
- **Go is hx64's outlier.** On the Mac, hx64's T1 takes 2.96 s against
  ha64's 0.55 s, a far wider gap than on any other workload.
- **Floating point is slow in ha64 on the amd64 host.** In the compute
  benchmarks (`zig build bench -Demu=hcpu -- compute`, at `7838bf6`),
  ha64's T1 ran the double-precision loop at 33x native, against 8x for
  h86's. Unicorn ran it at 18x. The other four compute benchmarks ran at
  3.5 to 20x.
- **Process start is expensive in the emulator.** On the amd64 host,
  `python3 -c pass` took 0.7 s on ha64's T1, against 15 ms native. Workloads
  made of many short processes, such as `git status`, run about 100x
  slower.

## Reproducing

The workload roots and the native tiers come from
[tools/workloads](../tools/workloads/README.md):

```sh
. scripts/env.sh
tools/workloads/roots.sh                       # the arm64 and 386 Alpine roots
zig build -Demu=hcpu -Doptimize=ReleaseFast -p .local/workloads/h9-zig
zig build web -Doptimize=ReleaseFast          # zig-out/web/h9-node
TIERS="t1 t0" tools/workloads/run.sh a64-      # T1 and T0 for arm64 guests
TIERS="hvf t1 t0" tools/workloads/run.sh a64-  # the same, plus HVF, on an arm64 Mac
```

The amd64 root used for the real program on an amd64 host, and for hx64, is
built the same way from `.local/linux/alpine-amd64`, with speedtest1 built
for `x86_64-linux-musl` and gowork for `GOARCH=amd64`.

For a wasm tier, run the same command line through `h9-node`, which needs
Node 24 or later with JavaScript Promise Integration:

```sh
H9_EMU_TIER=t1 zig-out/web/h9-node --arch arm64 --root .local/workloads/alpine-arm64 \
	--net enable sh -c "python3 /w/bench.py"
```

For v86, install it from npm and boot `vmlinuz-virt` from Alpine's
`linux-virt` package for x86, with the 386 workload root packed as a newc
cpio initramfs. An `/init` there runs each workload between serial-console
markers, which the host timestamps.
