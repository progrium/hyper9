#!/usr/bin/env bash
# Runs the workloads (tests/workloads): real programs on real roots
# through h9, in parallel, with each case's wall time. `zig build
# workloads` runs it with the h9 it just built.
#
#   scripts/workloads.sh H9 OUTDIR [name...]
#
# A case is a script in tests/workloads: NAME.sh runs under /bin/sh on the
# Linux root, and NAME.rc under rc on the 9front root. Comment lines at the
# top say what it must do:
#
#   # expect: TEXT    stdout has a line that is exactly TEXT (repeatable)
#   # status: N       it exits with N (default 0)
#   # timeout: SECS   it's killed after SECS (default 120)
#   # known: REASON   it's expected to fail, because of REASON; a known
#                     case that passes fails the run, so the line goes
#
# The environment picks the rest:
#
#   H9_WL_ARCH        the roots' architecture (default amd64)
#   H9_WL_BACKEND     the backend (default auto)
#   H9_WL_JOBS        cases at once (default the CPU count)
#   H9_WL_LINUX_ROOT  default .local/linux/workloads-<arch>
#                     (scripts/fetch.sh workloads)
#   H9_WL_NINE_ROOT   default .local/9front/root<arch>, else
#                     .local/9front/root
#
# A case whose root is missing is skipped. OUTDIR gets each case's stdout
# and stderr, and results.tsv (name, result, seconds); the summary goes to
# stdout, and to $GITHUB_STEP_SUMMARY as a table when that's set.
set -uo pipefail
. "$(dirname "$0")/env.sh"

if [ "${1:-}" = --one ]; then
	# One case: scripts/workloads.sh --one H9 OUTDIR FILE
	h9=$2 out=$3 file=$4
	name=$(basename "$file")
	name=${name%.*}
	hdr() { sed -n "s/^# $1: //p" "$file"; }
	status=$(hdr status | head -n1)
	timeout=$(hdr timeout | head -n1)
	known=$(hdr known | head -n1)
	cases=$(cd "$(dirname "$file")" && pwd)
	case $file in
	*.sh) root=$H9_WL_LINUX_ROOT probe=etc/os-release cmd=(/bin/sh "/mnt/term/cwd/$name.sh") ;;
	*.rc) root=$H9_WL_NINE_ROOT probe="$H9_WL_ARCH/bin/rc" cmd=(rc "/mnt/term/cwd/$name.rc") ;;
	esac
	if [ ! -e "$root/$probe" ]; then
		printf '%s\tskip\t0\n' "$name" >"$out/$name.result"
		exit 0
	fi
	now() { if [ -n "${EPOCHREALTIME:-}" ]; then echo "$EPOCHREALTIME"; else date +%s; fi; }
	t0=$(now)
	timeout "${timeout:-120}" "$h9" --backend "$H9_WL_BACKEND" --arch "$H9_WL_ARCH" \
		--root "$root" --cwd "$cases" "${cmd[@]}" >"$out/$name.out" 2>"$out/$name.err" </dev/null
	code=$?
	secs=$(awk -v a="$t0" -v b="$(now)" 'BEGIN{printf "%.2f", b-a}')
	why=
	if [ "$code" = 124 ]; then
		why="timed out after ${timeout:-120}s"
	elif [ "$code" != "${status:-0}" ]; then
		why="exited $code, not ${status:-0}"
	else
		while IFS= read -r want; do
			grep -qxF -- "$want" "$out/$name.out" || { why="no line \"$want\" in stdout"; break; }
		done < <(hdr expect)
	fi
	if [ -n "$known" ]; then
		if [ -n "$why" ]; then result=known; else result=fixed; why="passes, so its known line ($known) can go"; fi
	elif [ -n "$why" ]; then result=fail; else result=pass; fi
	printf '%s\t%s\t%s\t%s\n' "$name" "$result" "$secs" "$why" >"$out/$name.result"
	exit 0
fi

h9=${1:?usage: workloads.sh H9 OUTDIR [name...]}
out=${2:?usage: workloads.sh H9 OUTDIR [name...]}
shift 2
export H9_WL_ARCH=${H9_WL_ARCH:-amd64}
export H9_WL_BACKEND=${H9_WL_BACKEND:-auto}
export H9_WL_LINUX_ROOT=${H9_WL_LINUX_ROOT:-$H9_LOCAL/linux/workloads-$H9_WL_ARCH}
if [ -z "${H9_WL_NINE_ROOT:-}" ]; then
	H9_WL_NINE_ROOT=$H9_LOCAL/9front/root$H9_WL_ARCH
	[ -d "$H9_WL_NINE_ROOT" ] || H9_WL_NINE_ROOT=$H9_LOCAL/9front/root
fi
export H9_WL_NINE_ROOT
jobs=${H9_WL_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}

rm -rf "$out" && mkdir -p "$out"
files=()
for f in "$H9_ROOT"/tests/workloads/*.sh "$H9_ROOT"/tests/workloads/*.rc; do
	[ -e "$f" ] || continue
	n=$(basename "$f")
	n=${n%.*}
	if [ $# -gt 0 ]; then
		keep=
		for w in "$@"; do case $n in *"$w"*) keep=1 ;; esac; done
		[ -n "$keep" ] || continue
	fi
	files+=("$f")
done
[ ${#files[@]} -gt 0 ] || { echo "workloads: no cases" >&2; exit 1; }

echo "workloads: ${#files[@]} cases, $jobs at once, $H9_WL_ARCH on $H9_WL_BACKEND"
t0=$(date +%s)
printf '%s\0' "${files[@]}" | xargs -0 -P "$jobs" -n 1 "$0" --one "$h9" "$out"
cat "$out"/*.result | sort >"$out/results.tsv"
rm -f "$out"/*.result

failed=0
while IFS=$'\t' read -r name result secs why; do
	printf '%-28s %-6s %7ss  %s\n' "$name" "$result" "$secs" "$why"
	case $result in fail|fixed) failed=$((failed + 1)) ;; esac
done <"$out/results.tsv"
echo "workloads: $(awk -F'\t' '{n[$2]++} END{for (r in n) printf "%s %d, ", r, n[r]}' "$out/results.tsv" | sed 's/, $//') in $(($(date +%s) - t0))s"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### Workloads: $H9_WL_ARCH on $H9_WL_BACKEND"
		echo
		echo "| Case | Result | Seconds | Note |"
		echo "| --- | --- | ---: | --- |"
		awk -F'\t' '{printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}' "$out/results.tsv"
	} >>"$GITHUB_STEP_SUMMARY"
fi

[ "$failed" = 0 ] || { echo "workloads: $failed failed; stdout and stderr are in $out" >&2; exit 1; }
