# Emulator performance

> How fast h9's emulator CPUs run real programs: ha64 for arm64 guests,
> h86 for 386 guests, and hx64 for amd64 guests. Each runs on its JIT (T1)
> and on its interpreter alone (T0), natively and in WebAssembly. These
> numbers are measured snapshots, not targets, and they change as the CPUs
> do. [hcpu](../design/hcpu.md) is the design, and
> [tools/workloads](../tools/workloads/README.md) has the workloads.

With the JIT, an arm64 guest on an arm64 Mac runs 5 to 10 times slower than
the same program built for macOS. On an x86-64 Linux host it's 17 to 32
times slower. 386 and amd64 guests cost more: 8 to 62 times on the Mac, and
25 to 99 times on x86-64. In WebAssembly, T1 is 1.1 to 2 times slower than
native T1 on the x86-64 host, and 3 to 5.5 times slower on the Mac.

## How to read the tables

Each cell is wall time, then how many times slower than the real program
in parentheses. Every run's output matched the real program's. Columns go
from fastest to slowest:

- **Real program:** the same program built for the host and run there
  directly, whatever the guest architecture. Each host table says how it
  was built.
- **HVF:** on the Mac, the arm64 Alpine build on h9's hardware backend
  (`--backend hvf`), as a reference for what h9 costs without emulation.
- **T1:** the JIT, through `h9 --backend emu`.
- **wasm T1:** the same tier through `h9-node`, the WebAssembly build
  under Node.
- **v86:** for 386 guests only,
  [v86](https://github.com/copy/v86) 0.5.473 from npm under the same Node.
  It boots Alpine 3.22's x86 `virt` kernel with the same root as its
  initramfs. Its times run from a serial-console marker before each workload
  to one after it, so they leave out boot. h9's times include starting
  `h9-node`, which favors v86 a little on the short workloads.
- **T0 and wasm T0:** the interpreter alone (`H9_EMU_TIER=t0`), natively
  and in wasm.

A dash marks a run that can't work. The Go workload's HTTP server can't
listen on loopback in the wasm host, so Go has no wasm cells. It does run
under v86, which has a real kernel.

## The workloads

Every guest runs Alpine 3.22 with the same programs built for its
architecture, from `tools/workloads/roots.sh`:

| workload | what it runs |
| --- | --- |
| python sum | `python3 -c 'print(sum(range(10**7)))'` |
| python bench.py | `tools/workloads/bench.py`, a pure-Python benchmark |
| SQLite speedtest1 | `speedtest1 --testset main --size 25 --verify --memdb` |
| sqlite3 shell | a recursive query over 200,000 rows, from `tools/workloads/run.sh` |
| Go | `tools/workloads/gowork`: crypto/sha256, encoding/json, and net/http on loopback |

## arm64 host

A MacBook Pro with an M3 Max (Mac15,10) and 96 GB, on macOS 15.8.1. The
builds are ReleaseFast from main at 14a24c9, and `h9-node` runs on Node 26.
The real programs are native macOS programs: Homebrew Python 3.12.4 (Alpine
has 3.12), the system sqlite3 3.43.2, and speedtest1 and the Go program
built for darwin/arm64. v86 boots in 4 s.

### ha64 (arm64 guests)

| workload | real program | HVF | T1 | wasm T1 | T0 | wasm T0 |
| --- | --- | --- | --- | --- | --- | --- |
| python sum | 0.13 s | 0.16 s (1.2x) | 1.17 s (9.0x) | 5.30 s (41x) | 10.44 s (80x) | 30.89 s (238x) |
| python bench.py | 0.14 s | 0.17 s (1.2x) | 1.39 s (9.9x) | 7.71 s (55x) | 10.66 s (76x) | 28.64 s (205x) |
| SQLite speedtest1 | 0.33 s | 0.38 s (1.2x) | 2.08 s (6.3x) | 9.92 s (30x) | 18.49 s (56x) | 47.93 s (145x) |
| sqlite3 shell | 0.05 s | 0.04 s (0.8x) | 0.35 s (7.0x) | 1.42 s (28x) | 2.37 s (47x) | 7.03 s (141x) |
| Go | 0.10 s | 0.36 s (3.6x) | 0.55 s (5.5x) | — | 3.84 s (38x) | — |

### h86 (386 guests)

The real program and HVF columns run the same arm64 programs as the ha64
table, run again.

| workload | real program | HVF | T1 | wasm T1 | v86 | T0 | wasm T0 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| python sum | 0.11 s | 0.15 s (1.4x) | 4.67 s (42x) | 17.46 s (159x) | 15.78 s (143x) | 62.28 s (566x) | 120.63 s (1097x) |
| python bench.py | 0.17 s | 0.18 s (1.1x) | 3.14 s (18x) | 11.19 s (66x) | 6.97 s (41x) | 27.76 s (163x) | 51.51 s (303x) |
| SQLite speedtest1 | 0.34 s | 0.38 s (1.1x) | 4.31 s (13x) | 12.96 s (38x) | 7.56 s (22x) | 45.46 s (134x) | 83.03 s (244x) |
| sqlite3 shell | 0.09 s | 0.05 s (0.6x) | 0.69 s (7.7x) | 1.96 s (22x) | 1.30 s (14x) | 5.90 s (66x) | 11.80 s (131x) |
| Go | 0.10 s | 0.37 s (3.7x) | 6.22 s (62x) | — | 7.63 s (76x) | 39.68 s (397x) | — |

### hx64 (amd64 guests)

Measured on the `hx64` branch at e86efbc. There's no HVF column, since an
arm64 Mac can't run amd64 code in hardware.

| workload | real program | T1 | wasm T1 | T0 | wasm T0 |
| --- | --- | --- | --- | --- | --- |
| python sum | 0.13 s | 1.86 s (14x) | 7.09 s (55x) | 19.89 s (153x) | 46.91 s (361x) |
| python bench.py | 0.14 s | 2.39 s (17x) | 8.77 s (63x) | 21.12 s (151x) | 42.58 s (304x) |
| SQLite speedtest1 | 0.33 s | 3.07 s (9.3x) | 10.95 s (33x) | 37.70 s (114x) | 74.32 s (225x) |
| sqlite3 shell | 0.05 s | 0.46 s (9.2x) | 1.67 s (33x) | 4.75 s (95x) | 9.92 s (198x) |
| Go | 0.10 s | 2.96 s (30x) | — | 51.22 s (512x) | — |

## x86-64 host

A cloud Xeon at 2.3 GHz with 4 cores and no KVM, running Linux. The builds
are ReleaseFast from main at 8067d1b, and `h9-node` runs on Node 25 (V8
14.1). The real program is the same Alpine 3.22 program built for x86-64 and
run in a chroot on the host. v86 boots in 9 s.

### ha64 (arm64 guests)

| workload | real program | T1 | wasm T1 | T0 | wasm T0 |
| --- | --- | --- | --- | --- | --- |
| python sum | 0.18 s | 4.18 s (23x) | 6.65 s (37x) | 12.64 s (70x) | 26.29 s (146x) |
| python bench.py | 0.22 s | 5.79 s (26x) | 10.51 s (48x) | 17.03 s (77x) | 30.47 s (138x) |
| SQLite speedtest1 | 0.47 s | 8.08 s (17x) | 14.31 s (30x) | 30.72 s (65x) | 50.30 s (107x) |
| sqlite3 shell | 0.07 s | 1.37 s (20x) | 2.06 s (29x) | 5.04 s (72x) | 8.37 s (120x) |
| Go | 0.13 s | 4.12 s (32x) | — | 7.00 s (54x) | — |

### h86 (386 guests)

| workload | real program | T1 | wasm T1 | v86 | T0 | wasm T0 |
| --- | --- | --- | --- | --- | --- | --- |
| python sum | 0.18 s | 12.99 s (72x) | 20.06 s (111x) | 26.85 s (149x) | 67.66 s (376x) | 157.37 s (874x) |
| python bench.py | 0.23 s | 8.69 s (38x) | 15.29 s (66x) | 14.36 s (62x) | 35.08 s (153x) | 70.86 s (308x) |
| SQLite speedtest1 | 0.47 s | 12.34 s (26x) | 19.62 s (42x) | 16.46 s (35x) | 55.64 s (118x) | 113.12 s (241x) |
| sqlite3 shell | 0.07 s | 1.87 s (27x) | 2.74 s (39x) | 2.60 s (37x) | 9.03 s (129x) | 16.70 s (239x) |
| Go | 0.15 s | 14.87 s (99x) | — | 17.73 s (118x) | 45.14 s (301x) | — |

### hx64 (amd64 guests)

Measured on the `hx64` branch at e86efbc. On this host, amd64 programs
normally run at hardware speed on the native backend or KVM. These rows
show the emulator alone.

| workload | real program | T1 | wasm T1 | T0 | wasm T0 |
| --- | --- | --- | --- | --- | --- |
| python sum | 0.18 s | 7.28 s (40x) | 14.81 s (82x) | 26.88 s (149x) | 62.98 s (350x) |
| python bench.py | 0.22 s | 8.83 s (40x) | 15.16 s (69x) | 34.07 s (155x) | 70.08 s (319x) |
| SQLite speedtest1 | 0.47 s | 11.52 s (25x) | 20.51 s (44x) | 55.89 s (119x) | 120.88 s (257x) |
| sqlite3 shell | 0.07 s | 2.24 s (32x) | 2.56 s (37x) | 8.95 s (128x) | 17.11 s (244x) |
| Go | 0.13 s | 7.63 s (59x) | — | 49.98 s (384x) | — |

## What stands out

- **ha64 is the fastest of the three everywhere,** including in wasm. hx64
  comes next: its T1 beats h86's on every workload, by 1.3 to 2.5 times on
  the Mac.
- **The x86-64 host gives hx64 no advantage.** hx64's T1 is slower than
  ha64's there, even though the guest and the host share an architecture.
- **v86 tracks h86's wasm T1.** It's within 1.3 times of it either way on the x86-64 host,
  and up to 1.7 times faster on the Mac, where wasm costs h9 more.
- **Go is hx64's outlier.** On the Mac, hx64's T1 takes 2.96 s against
  ha64's 0.55 s, a far wider gap than on any other workload.
- **Floating point is slow in ha64 on the x86-64 host.** In the compute
  benchmarks (`zig build bench -Demu=hcpu -- compute`, measured at
  7838bf6), ha64's T1 ran the double-precision loop at 33 times native,
  against 8 times for h86's and 18 times for Unicorn. ha64's other four
  compute benchmarks ran at 3.5 to 20 times.
- **Starting a process is expensive in the emulator.** On the x86-64 host,
  `python3 -c pass` took 0.7 s on ha64's T1, against 15 ms native. A
  workload made of many short processes, such as `git status`, runs about
  100 times slower.

## Measuring it yourself

Build the roots and a ReleaseFast h9, as in
[tools/workloads](../tools/workloads/README.md):

    tools/workloads/roots.sh
    zig build -Demu=hcpu -Doptimize=ReleaseFast -p .local/workloads/h9-zig
    zig build web -Doptimize=ReleaseFast

`tools/workloads/run.sh` runs the native tiers, with `TIERS="hvf t1 t0"` on
an arm64 Mac. For a wasm tier, run the same command line through
`zig-out/web/h9-node` with `H9_EMU_TIER` set to `t1` or `t0`:

    H9_EMU_TIER=t1 zig-out/web/h9-node --arch 386 \
        --root .local/workloads/alpine-386 --net enable \
        sh -c "python3 /w/bench.py"

`h9-node` needs Node 24 or later. On macOS, `roots.sh` installs packages
by running `apk` under h9, so it needs an h9 on `PATH` or in `H9`.
