#!/usr/bin/env bash
# Runs Go's standard library tests for time, syscall, os and runtime on the
# emulator (design/go-compat.md), and prints pass, skip and fail
# counts for each package. Not a gate: it finds gaps the go-compat cases
# miss. `zig build go-stdtest -Demu=unicorn` runs it.
#
#   scripts/go-stdtest.sh H9 OUTDIR [PACKAGE...]
#
# Test binaries are built on the host with `go test -c` at GO_VERSION from
# scripts/pins.sh, and run with --cwd set to the package's directory in the
# toolchain's GOROOT, so testdata is at /mnt/term/cwd. Tests that can't
# pass yet, mostly ones that exec go or 9front commands (there's no
# /amd64/bin), are skipped with -test.skip from scripts/go-stdtest.skip.
# Each package's output is left in OUTDIR/<package>.out.
set -euo pipefail
h9=$1 out=$2
shift 2
pkgs=("$@")
[ ${#pkgs[@]} -gt 0 ] || pkgs=(time syscall os runtime)
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pins.sh"

command -v go >/dev/null || { echo "go-stdtest: no go on PATH" >&2; exit 1; }
export GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 GOTOOLCHAIN=go$GO_VERSION
goroot=$(go env GOROOT)
mkdir -p "$out"
out=$(cd "$out" && pwd)
case $h9 in /*) ;; *) h9=$PWD/$h9 ;; esac

# A root holding only the directories the namespace binds onto: the test
# binaries are amd64, and the arm64 root tree has nothing they use.
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{bin,dev,env,fd,mnt/term/cwd,net,net.alt,proc,root,srv,tmp}

# The -test.skip pattern for a package: its lines in the skip list, joined.
skips() {
	sed -e 's/#.*//' "$here/go-stdtest.skip" | awk -v p="$1" '$1 == p && NF > 1 { print $2 }' | paste -sd '|' -
}

printf '%-10s %6s %6s %6s  %s\n' package pass skip fail result
status=0
for p in "${pkgs[@]}"; do
	tags=()
	# Without GOROOT/lib in the guest, time loads its zones from the binary.
	[ "$p" = time ] && tags=(-tags timetzdata)
	go test -c "${tags[@]}" -o "$out/$p.test" "$p"
	args=(-test.v -test.short -test.timeout 25m)
	skip=$(skips "$p")
	[ -n "$skip" ] && args+=(-test.skip "$skip")
	rc=0
	(cd "$out" && "$h9" --backend emu --arch amd64 --root "$root" --memory 4G --timeout 30m \
		--cwd "$goroot/src/$p" "./$p.test" "${args[@]}") >"$out/$p.out" 2>&1 || rc=$?
	pass=$(grep -c '^--- PASS' "$out/$p.out" || true)
	skipped=$(grep -c '^--- SKIP' "$out/$p.out" || true)
	fail=$(grep -c '^--- FAIL' "$out/$p.out" || true)
	result=ok
	if [ "$rc" -ne 0 ]; then
		result="exit $rc"
		status=1
	fi
	printf '%-10s %6s %6s %6s  %s\n' "$p" "$pass" "$skipped" "$fail" "$result"
done
echo "output in $out"
exit $status
