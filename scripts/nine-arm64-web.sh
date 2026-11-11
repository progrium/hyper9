#!/usr/bin/env bash
# Makes the web demo's arm64 9front layer: the slim arm64 root
# (design/0064-multicall.md) at .local/9front/slim-<release>-arm64, which
# `zig build web` packs into zig-out/web/nine-arm64.h9a with
# src/web/nine-arm64.list for ?linux's /9 (design/0012-browser-host.md,
# Updates):
#
#   zig build isoroot -- .local/9front/9front-<release>.386.iso .local/9front/root386
#   scripts/nine-arm64-web.sh
#
# The release's ISO has the 386 compilers for every architecture but no
# arm64 libraries, so this copies the 386 root, cross-compiles its
# libraries with objtype=arm64 inside h9 (about 10 minutes on the
# emulator), and runs zig build slim -Darch=arm64 over the copy, which
# builds 9box with the 386 compilers. H9 names the h9 for the first step
# (default zig-out/bin/h9; zig build slim builds its own).
set -euo pipefail
. "$(dirname "$0")/env.sh"

src="$H9_LOCAL/9front/root386"
dir="$H9_LOCAL/9front/root386-arm64lib"
h9=${H9:-$H9_ROOT/zig-out/bin/h9}
[ -x "$src/386/bin/rc" ] || { echo "nine-arm64-web: no $src; run zig build isoroot" >&2; exit 1; }
[ -x "$h9" ] || { echo "nine-arm64-web: no $h9; run zig build" >&2; exit 1; }

if [ ! -f "$dir/arm64/lib/libc.a" ]; then
	rm -rf "$dir" "$dir.tmp"
	cp -a "$src" "$dir.tmp"
	"$h9" --arch 386 --root "$dir.tmp" --writable "$dir.tmp" --rc 'cd /sys/src && objtype=arm64 mk libs'
	mv "$dir.tmp" "$dir"
fi
cd "$H9_ROOT"
zig build slim -Darch=arm64 -Demu=zig -Droot="$dir"
