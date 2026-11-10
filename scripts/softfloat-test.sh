#!/usr/bin/env bash
# Checks src/interp/softfloat.zig, the shared binary16/32/64 core, against
# Berkeley TestFloat: arithmetic, fused multiply-add, square root,
# round-to-integral, comparisons, and conversions, for f16, f32, and f64,
# in every rounding mode SoftFloat has, with tininess detected both before
# and after rounding. It builds SoftFloat 3e and TestFloat 3e (pinned in
# scripts/testfloat.sh) into .local/src, then pipes testfloat_gen into
# softfloat_vectors.zig.
#
#   scripts/softfloat-test.sh [-level 2] [function...]   (default: all)
#
# `--sample` regenerates the sample `zig build test` runs,
# src/interp/softfloat-vectors.txt.
set -euo pipefail
. "$(dirname "$0")/env.sh"

eval "$(grep -E '^(SOFTFLOAT|TESTFLOAT)_(REPO|REV)=' "$H9_ROOT/scripts/testfloat.sh")"

level=1
sample=
funcs=()
while [ $# -gt 0 ]; do
	case $1 in
	-level) level=$2; shift 2 ;;
	--sample) sample=1; shift ;;
	-*) echo "softfloat-test: unknown option '$1'" >&2; exit 2 ;;
	*) funcs+=("$1"); shift ;;
	esac
done

# SoftFloat's Linux-x86_64-GCC build is plain C for any 64-bit little-endian
# host with a GCC-compatible cc (macOS's clang included); its templates
# need editing first.
case "$(uname -s)-$(uname -m)" in
Linux-x86_64 | Linux-aarch64 | Darwin-arm64 | Darwin-x86_64) plat=Linux-x86_64-GCC ;;
*) echo "softfloat-test: no SoftFloat build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

src="$H9_LOCAL/src"
mkdir -p "$src"
fetch() {
	local repo=$1 dir="$src/$2" rev=$3
	[ -d "$dir/.git" ] || git init -q "$dir"
	if [ "$(git -C "$dir" rev-parse -q --verify HEAD || true)" != "$rev" ]; then
		git -C "$dir" fetch -q --depth 1 "$repo" "$rev"
		git -C "$dir" checkout -q --detach "$rev"
	fi
}
fetch "$SOFTFLOAT_REPO" berkeley-softfloat-3 "$SOFTFLOAT_REV"
fetch "$TESTFLOAT_REPO" berkeley-testfloat-3 "$TESTFLOAT_REV"

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
sfb="$src/berkeley-softfloat-3/build/$plat"
tfb="$src/berkeley-testfloat-3/build/$plat"
[ -f "$sfb/softfloat.a" ] || make -s -C "$sfb" -j"$jobs" >/dev/null
gen="$tfb/testfloat_gen"
[ -x "$gen" ] || make -s -C "$tfb" -j"$jobs" SOFTFLOAT_DIR=../../../berkeley-softfloat-3 \
	PLATFORM="$plat" testfloat_gen >/dev/null

check="$H9_LOCAL/bin/softfloat_vectors"
mkdir -p "$H9_LOCAL/bin"
zig build-exe -OReleaseFast "$H9_ROOT/src/interp/softfloat_vectors.zig" -femit-bin="$check"

all=()
for f in f16 f32 f64; do
	all+=("${f}_add" "${f}_sub" "${f}_mul" "${f}_div" "${f}_sqrt" "${f}_mulAdd" "${f}_roundToInt"
		"${f}_eq" "${f}_le" "${f}_lt" "${f}_eq_signaling" "${f}_le_quiet" "${f}_lt_quiet")
	for i in i32 i64 ui32 ui64; do all+=("${f}_to_$i" "${i}_to_$f"); done
	for g in f16 f32 f64; do [ $f = $g ] || all+=("${f}_to_$g"); done
done
[ ${#funcs[@]} -gt 0 ] || funcs=("${all[@]}")
modes=(near_even min_mag min max near_max_mag odd)
tfmode() { case $1 in min_mag) echo minMag ;; near_max_mag) echo near_maxMag ;; *) echo "$1" ;; esac; }

out="$H9_ROOT/src/interp/softfloat-vectors.txt"
run() {
	local f=$1 m=$2 t=$3 e=$4
	if [ -n "$sample" ]; then
		echo "= $f $m $t $e" >>"$out"
		"$gen" -level 1 -r"$(tfmode "$m")" -tininess"$t" -"$e" "$f" |
			awk '{ c[NR] = $0 } END { s = NR / 24; if (s < 1) s = 1; for (i = 1; i <= NR; i += s) print c[int(i)] }' >>"$out"
	else
		"$gen" -level "$level" -r"$(tfmode "$m")" -tininess"$t" -"$e" "$f" | "$check" "$f" "$m" "$t" "$e" || failed=1
	fi
}

if [ -n "$sample" ]; then
	printf '%s\n' "# A sample of Berkeley TestFloat 3e's level 1 vectors for softfloat.zig's tests," \
		"# 24 spread through each run; regenerate with scripts/softfloat-test.sh --sample." >"$out"
fi
failed=0
for f in "${funcs[@]}"; do
	case $f in
	*_eq | *_le | *_lt | *_eq_signaling | *_le_quiet | *_lt_quiet | f16_to_f32 | f16_to_f64 | f32_to_f64 | i32_to_f64 | ui32_to_f64)
		run "$f" near_even after notexact ;;
	*_to_i32 | *_to_i64 | *_to_ui32 | *_to_ui64 | *_roundToInt)
		for m in "${modes[@]}"; do for e in exact notexact; do run "$f" "$m" after "$e"; done; done ;;
	*)
		for m in "${modes[@]}"; do for t in before after; do run "$f" "$m" "$t" notexact; done; done ;;
	esac
done
exit $failed
