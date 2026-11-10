#!/usr/bin/env bash
# Checks src/interp/x86/f80.zig, the Zig port of SoftFloat's extF80,
# against Berkeley TestFloat: every function f80.zig has, in every rounding
# mode, and for add, sub, mul, div, and sqrt in every rounding precision.
# It builds SoftFloat 3e and TestFloat 3e (pinned below) into .local/src
# with the host's cc and make, then pipes testfloat_gen into
# f80_vectors.zig. Expect a few minutes at level 1, many hours at level 2.
#
#   scripts/testfloat.sh [-level 2] [function...]   (default: all)
#
# It also regenerates f80.zig's sample, src/interp/x86/f80-vectors.txt,
# with `scripts/testfloat.sh --sample`.
set -euo pipefail
. "$(dirname "$0")/env.sh"

SOFTFLOAT_REPO=https://github.com/ucb-bar/berkeley-softfloat-3
SOFTFLOAT_REV=07ebd29db0cfb55723a79fbbffe99103ef38e305
TESTFLOAT_REPO=https://github.com/ucb-bar/berkeley-testfloat-3
TESTFLOAT_REV=a9c849f1b0eb0264b626d9686ffae167d996e3be

level=1
sample=
funcs=()
while [ $# -gt 0 ]; do
	case $1 in
	-level) level=$2; shift 2 ;;
	--sample) sample=1; shift ;;
	-*) echo "testfloat: unknown option '$1'" >&2; exit 2 ;;
	*) funcs+=("$1"); shift ;;
	esac
done

case "$(uname -s)-$(uname -m)" in
Linux-x86_64) plat=Linux-x86_64-GCC ;;
Linux-aarch64 | Darwin-arm64 | Darwin-x86_64) plat=template-FAST_INT64 ;;
*) echo "testfloat: no SoftFloat build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
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
tfb="$src/berkeley-testfloat-3/build/$([ "$plat" = Linux-x86_64-GCC ] && echo "$plat" || echo template)"
if [ ! -f "$sfb/softfloat.a" ]; then
	make -s -C "$sfb" -j"$jobs" >/dev/null
fi
gen="$tfb/testfloat_gen"
if [ ! -x "$gen" ]; then
	make -s -C "$tfb" -j"$jobs" SOFTFLOAT_DIR=../../../berkeley-softfloat-3 \
		PLATFORM="$plat" testfloat_gen >/dev/null
fi

check="$H9_LOCAL/bin/f80_vectors"
mkdir -p "$H9_LOCAL/bin"
zig build-exe -OReleaseFast "$H9_ROOT/src/interp/x86/f80_vectors.zig" -femit-bin="$check"

all=(extF80_add extF80_sub extF80_mul extF80_div extF80_sqrt extF80_rem extF80_roundToInt
	extF80_eq extF80_le extF80_lt extF80_eq_signaling extF80_le_quiet extF80_lt_quiet
	extF80_to_i32 extF80_to_i64 extF80_to_i32_r_minMag extF80_to_i64_r_minMag
	extF80_to_f32 extF80_to_f64 i32_to_extF80 i64_to_extF80 f32_to_extF80 f64_to_extF80)
[ ${#funcs[@]} -gt 0 ] || funcs=("${all[@]}")
modes=(near_even min_mag min max near_max_mag)
tfmode() { case $1 in min_mag) echo minMag ;; near_max_mag) echo near_maxMag ;; *) echo "$1" ;; esac; }

# run func mode precision exact: one testfloat_gen run, checked (or, for
# --sample, 32 cases spread through it appended to the sample under its header).
out="$H9_ROOT/src/interp/x86/f80-vectors.txt"
run() {
	local f=$1 m=$2 p=$3 e=$4 gf=$1
	case $f in *_r_minMag) gf=${f%_r_minMag} ;; esac
	if [ -n "$sample" ]; then
		echo "= $f $m $p $e" >>"$out"
		"$gen" -level 1 -r"$(tfmode "$m")" -precision"$p" -"$e" "$gf" |
			awk '{ c[NR] = $0 } END { s = NR / 32; if (s < 1) s = 1; for (i = 1; i <= NR; i += s) print c[int(i)] }' >>"$out"
	else
		"$gen" -level "$level" -r"$(tfmode "$m")" -precision"$p" -"$e" "$gf" | "$check" "$f" "$m" "$p" "$e" || failed=1
	fi
}

if [ -n "$sample" ]; then
	printf '%s\n' "# A sample of Berkeley TestFloat 3e's level 1 vectors for f80.zig's tests," \
		"# 32 spread through each run; regenerate with scripts/testfloat.sh --sample." >"$out"
fi
failed=0
for f in "${funcs[@]}"; do
	case $f in
	extF80_add | extF80_sub | extF80_mul | extF80_div | extF80_sqrt)
		for m in "${modes[@]}"; do for p in 32 64 80; do run "$f" "$m" "$p" notexact; done; done ;;
	extF80_roundToInt | extF80_to_i32 | extF80_to_i64)
		for m in "${modes[@]}"; do for e in exact notexact; do run "$f" "$m" 80 "$e"; done; done ;;
	*_r_minMag)
		for e in exact notexact; do run "$f" min_mag 80 "$e"; done ;;
	extF80_rem | extF80_to_f32 | extF80_to_f64)
		for m in "${modes[@]}"; do run "$f" "$m" 80 notexact; done ;;
	*) run "$f" near_even 80 notexact ;;
	esac
done
exit $failed
