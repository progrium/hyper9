# Real-world workloads

Programs people run, on each of the emulator's tiers, with their output
checked against a reference (native, or Unicorn) and their wall time.

    tools/workloads/roots.sh     # the arm64 and 386 Alpine roots, once
    zig build -Demu=hcpu -Doptimize=ReleaseFast -p .local/workloads/h9-zig
    zig build -Demu=unicorn -Doptimize=ReleaseFast -p .local/workloads/h9-unicorn
    tools/workloads/run.sh       # every workload on every tier
    tools/workloads/run.sh a64-  # only those whose names contain a64-
    TIERS="hvf t1" tools/workloads/run.sh a64-   # on an arm64 Mac
    tools/workloads/run.sh -n    # list them

On Linux, -Demu=unicorn also needs -Dtarget=x86_64-linux-musl (or
aarch64-linux-musl). The workloads:

- arm64 Alpine 3.22: python3 (`sum(range(10**7))` and bench.py, a
  pure-Python benchmark), SQLite's speedtest1 (main test set, size 25, in
  memory, its verification hash checked), the sqlite3 shell, `git status`
  on a clone of this repository with 200 untracked and 50 modified files,
  and gowork/ (Go: crypto/sha256, encoding/json, and net/http on loopback).
- 386 Alpine 3.22: the same python3, speedtest1, sqlite3, and Go.
- 9front 386: an rc pipeline (seq, sed, grep, sort, uniq, tr, wc over
  /lib/words), awk, and hoc's floating point.

run.sh writes each run's output to .local/workloads/out/ and a results
table to .local/workloads/out/results.md.
