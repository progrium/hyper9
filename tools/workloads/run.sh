#!/bin/bash
# tools/workloads/run.sh [-n] [FILTER]: the real-world workloads on each
# tier, with their output checked against a reference and their wall time.
#
# Tiers (TIERS, space-separated; default "native unicorn t1 t0"):
#   t1       h9 --backend emu, the zig emulator's default (JIT) tier
#   t0       the same with H9_EMU_TIER=t0, the interpreter alone
#   unicorn  h9 built with -Demu=unicorn
#   native   the host itself, chrooted (as root), for 386 Linux on an
#            x86-64 Linux host; skipped elsewhere
#   hvf, kvm h9 with that hardware backend (H9 for its binary, default
#            h9-zig's), for arm64 on an arm64 host
#
# The reference output is the first tier in TIERS to finish: native
# where there is one, else Unicorn.
# Workloads whose name doesn't contain FILTER are skipped; -n lists them.
# Needs tools/workloads/roots.sh first, a ReleaseFast h9 for each
# emulator, and .local/9front/root (NINE_ROOT) for the 9front ones:
#
#   zig build -Demu=zig -Doptimize=ReleaseFast -p .local/workloads/h9-zig
#   zig build -Demu=unicorn -Doptimize=ReleaseFast -p .local/workloads/h9-unicorn
#
# (on Linux, -Demu=unicorn also needs -Dtarget=<arch>-linux-musl). Outputs
# and a results table go to .local/workloads/out/; TIMEOUT is each run's
# limit in seconds, where the host has timeout(1) or gtimeout.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
W="$repo/.local/workloads"
OUT="$W/out"
NINE="${NINE_ROOT:-$repo/.local/9front/root}"
TIMEOUT="${TIMEOUT:-3600}"
TIERS="${TIERS:-native unicorn t1 t0}"
mkdir -p "$OUT"

list=0
if [ "${1:-}" = -n ]; then list=1; shift; fi
filter="${1:-}"

# name|kind|cwd|command (a shell command line, run by the guest's sh, or
# rc for 9front). Each prints only what the run must reproduce.
WORKLOADS=$(cat <<'X'
a64-py-sum|arm64||python3 -c 'print(sum(range(10**7)))'
a64-py-bench|arm64||python3 /w/bench.py
a64-speedtest1|arm64||/w/speedtest1 --testset main --size 25 --verify --memdb | grep Verification
a64-sqlite3|arm64||sqlite3 :memory: "with recursive c(x) as (select 1 union all select x+1 from c where x<200000) select count(*), sum(x), sum(x*x)%1000003, printf('%.6f', avg(sqrt(x))) from c;"
a64-git-status|arm64|/w/tree|git status --porcelain | sort | sha256sum; git log --oneline | wc -l
a64-go|arm64||/w/gowork 2>/dev/null
386-py-sum|386||python3 -c 'print(sum(range(10**7)))'
386-py-bench|386||python3 /w/bench.py
386-speedtest1|386||/w/speedtest1 --testset main --size 25 --verify --memdb | grep Verification
386-sqlite3|386||sqlite3 :memory: "with recursive c(x) as (select 1 union all select x+1 from c where x<200000) select count(*), sum(x), sum(x*x)%1000003, printf('%.6f', avg(sqrt(x))) from c;"
386-go|386||/w/gowork 2>/dev/null
9-rc-pipeline|9front||for(i in `{seq 1 300}) echo $i | sed 's/1/one/g'; seq 1 20000 | grep 7 | sort -r | uniq | wc -l; cat /lib/words /lib/words | tr A-Z a-z | sort | uniq -c | sort -nr | sed 10q
9-awk|9front||seq 1 200000 | awk '{ s += $1; q += sqrt($1); if ($1 % 7 == 0) n++ } END { printf "%.0f %.6f %d\n", s, q, n }'; awk 'BEGIN { for (i = 0; i < 100000; i++) a[i % 977] = a[i % 977] i % 10; for (k in a) t += length(a[k]); print t }'
9-hoc|9front||{echo 'x = 0'; echo 'i = 1'; echo 'while (i <= 200000) {'; echo 'x = x + sin(i) * exp(-i/100000) + sqrt(i)'; echo 'i = i + 1'; echo '}'; echo x; echo 'atan(1)*4'; echo '2^0.5'; echo 'log(10)'; echo '10^-3'} | hoc
X
)

if command -v timeout >/dev/null; then to="timeout $TIMEOUT"
elif command -v gtimeout >/dev/null; then to="gtimeout $TIMEOUT"
else to=""; fi
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
native_ok=0
[ "$(uname -s)/$(uname -m)" = Linux/x86_64 ] && [ "$(id -u)" = 0 ] && native_ok=1

h9() { # tier arch cwd cmd
	local tier=$1 arch=$2 cwd=$3 cmd=$4 bin root
	local backend=emu
	case $tier in
	unicorn) bin="$W/h9-unicorn/bin/h9" ;;
	hvf | kvm) bin="${H9:-$W/h9-zig/bin/h9}" backend=$tier ;;
	*) bin="$W/h9-zig/bin/h9" ;;
	esac
	if [ "$arch" = 9front ]; then
		H9_EMU_TIER=$tier $to "$bin" --backend $backend --arch 386 --root "$NINE" --rc "$cmd"
		return
	fi
	root="$W/alpine-$arch"
	if [ "$tier" = native ]; then
		$to chroot "$root" /bin/sh -c "cd ${cwd:-/} && $cmd"
		return
	fi
	# --net enable: the Go program serves HTTP on loopback.
	H9_EMU_TIER=$tier $to "$bin" --backend $backend --arch "$arch" --root "$root" --net enable sh -c "cd ${cwd:-/} && $cmd"
}

table="$OUT/results.md"
[ $list = 1 ] || printf '| workload | tier | status | seconds |\n|---|---|---|---|\n' >"$table"
echo "$WORKLOADS" | while IFS='|' read -r name arch cwd cmd; do
	[ -n "$name" ] || continue
	case $name in *"$filter"*) ;; *) continue ;; esac
	if [ $list = 1 ]; then echo "$name ($arch): $cmd"; continue; fi
	ref=""
	for tier in $TIERS; do
		[ "$tier" = native ] && { [ "$arch" != 386 ] || [ $native_ok = 0 ]; } && continue
		o="$OUT/$name.$tier"
		t0=$(now)
		h9 "$tier" "$arch" "$cwd" "$cmd" >"$o.out" 2>"$o.err" </dev/null
		code=$?
		t1=$(now)
		secs=$(echo "$t1 - $t0" | bc)
		if [ $code = 124 ] && [ -n "$to" ]; then
			status="timeout"
		elif [ $code != 0 ]; then
			status="exit $code"
		elif [ -z "$ref" ]; then
			ref="$o.out"
			status="reference"
		elif cmp -s "$ref" "$o.out"; then
			status="ok"
		else
			status="DIFFERS"
		fi
		printf '| %s | %s | %s | %.2f |\n' "$name" "$tier" "$status" "$secs" | tee -a "$table"
	done
done
