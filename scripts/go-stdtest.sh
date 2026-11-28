#!/usr/bin/env bash
# Runs Go's standard library tests for time, syscall, os and runtime as
# Linux binaries in h9, through the Linux personality
# (design/epoch-0/linux-threads.md), and prints pass, skip and fail counts
# for each package. Not a gate: it finds gaps the Go integration cases
# miss. `zig build go-stdtest` runs it.
#
#   scripts/go-stdtest.sh H9 OUTDIR [PACKAGE...]
#
# Test binaries are built on the host with `go test -c` at GO_VERSION from
# scripts/pins.sh, for H9_STDTEST_ARCH (arm64, amd64 or 386; the host's by
# default), and run on H9_STDTEST_ENGINE (hcpu by default) in the Alpine
# root for that architecture from `scripts/fetch.sh alpine-<arch>`, with
# --cwd set to the package's directory in the toolchain's GOROOT, so
# testdata is at /mnt/term/cwd, and GOROOT at its host path too. Tests that stop a whole package run are
# skipped with -test.skip from scripts/go-stdtest.skip. Each package's
# output is left in OUTDIR/<package>.out.
set -euo pipefail
h9=$1 out=$2
shift 2
pkgs=("$@")
[ ${#pkgs[@]} -gt 0 ] || pkgs=(time syscall os runtime)
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pins.sh"

command -v go >/dev/null || { echo "go-stdtest: no go on PATH" >&2; exit 1; }
arch=${H9_STDTEST_ARCH:-}
if [ -z "$arch" ]; then
	case $(uname -m) in
	arm64 | aarch64) arch=arm64 ;;
	*) arch=amd64 ;;
	esac
fi
engine=${H9_STDTEST_ENGINE:-hcpu}
root=$here/../.local/linux/alpine-$arch
[ -f "$root/etc/os-release" ] || { echo "go-stdtest: no Alpine root at $root; scripts/fetch.sh alpine-$arch makes it" >&2; exit 1; }
root=$(cd "$root" && pwd)
export GOOS=linux GOARCH=$arch CGO_ENABLED=0 GOTOOLCHAIN=go$GO_VERSION
goroot=$(go env GOROOT)
# Some tests open their own source by the path compiled into them, so
# GOROOT is also bound at its host path: at the first directory on the way
# down that the Alpine root doesn't have, since a mount point has to exist.
p=
for c in $(echo "${goroot#/}" | tr / ' '); do
	p=$p/$c
	[ -e "$root$p" ] || break
done
gobind=$p
mkdir -p "$out"
out=$(cd "$out" && pwd)
case $h9 in /*) ;; *) h9=$PWD/$h9 ;; esac

# The -test.skip pattern for a package: its lines in the skip list, joined.
skips() {
	sed -e 's/#.*//' "$here/go-stdtest.skip" | awk -v p="$1" '$1 == p && NF > 1 { print $2 }' | paste -sd '|' -
}

echo "go-stdtest: linux/$arch on $engine"
printf '%-10s %6s %6s %6s  %s\n' package pass skip fail result
status=0
for p in "${pkgs[@]}"; do
	tags=()
	# Alpine's minirootfs has no zoneinfo, so time loads its zones from
	# the binary.
	[ "$p" = time ] && tags=(-tags timetzdata)
	# ${tags[@]+...}: macOS's bash 3.2 calls an empty array unbound under set -u.
	go test -c ${tags[@]+"${tags[@]}"} -o "$out/$p.test" "$p"
	args=(-test.v -test.short -test.timeout 25m)
	skip=$(skips "$p")
	[ -n "$skip" ] && args+=(-test.skip "$skip")
	rc=0
	# The binary is bound at /opt/go-stdtest, since the cwd is the
	# package's source directory.
	# --net enable: os's splice and sendfile tests listen on loopback TCP.
	"$h9" --engine "$engine" --arch "$arch" --net enable --dir "$root:#L" --dir "$gobind:#L$gobind" --dir "$out:#L/opt/go-stdtest" \
		--timeout 30m --cwd "$goroot/src/$p" "/opt/go-stdtest/$p.test" "${args[@]}" >"$out/$p.out" 2>&1 || rc=$?
	pass=$(grep -c -- '--- PASS' "$out/$p.out" || true)
	skipped=$(grep -c -- '--- SKIP' "$out/$p.out" || true)
	fail=$(grep -c -- '--- FAIL' "$out/$p.out" || true)
	result=ok
	if [ "$rc" -ne 0 ]; then
		result="exit $rc"
		status=1
	fi
	printf '%-10s %6s %6s %6s  %s\n' "$p" "$pass" "$skipped" "$fail" "$result"
done
echo "output in $out"
exit $status
