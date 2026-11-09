#!/usr/bin/env bash
# Makes an Alpine amd64 root with Wine 11 in it, at .local/linux/wine-amd64,
# for the wine-draw case in tests/backends.zig (design/wine-draw.md):
#
#   scripts/wine-root.sh && export H9_TEST_WINE_ROOT=$PWD/.local/linux/wine-amd64
#   zig build wine test
#
# It's about 600 MB. Wine comes from Alpine's own packages, checked against
# the root's signing keys, so its version is the one winedraw targets only
# while Alpine 3.24 ships Wine 11.0 (WINE_VERSION in scripts/pins.sh).
set -euo pipefail
. "$(dirname "$0")/env.sh"

ALPINE=3.24
MINIROOT=alpine-minirootfs-3.24.4-x86_64.tar.gz
APK_STATIC=apk-tools-static-3.0.9-r0.apk
MIRROR=https://dl-cdn.alpinelinux.org/alpine

dir="$H9_LOCAL/linux/wine-amd64"
if [ -x "$dir/usr/bin/wine" ]; then
	echo "linux/wine-amd64: $("$dir/usr/bin/wine" --version 2>/dev/null || echo present)"
	exit 0
fi
tmp="$H9_LOCAL/cache/wine-root.tmp"
rm -rf "$tmp" && mkdir -p "$tmp/root" "$tmp/apk"
curl -fsSL "$MIRROR/v$ALPINE/releases/x86_64/$MINIROOT" | tar -xz -C "$tmp/root"
curl -fsSL "$MIRROR/v$ALPINE/main/x86_64/$APK_STATIC" | tar -xz -C "$tmp/apk" 2>/dev/null
printf '%s\n' "$MIRROR/v$ALPINE/main" "$MIRROR/v$ALPINE/community" >"$tmp/root/etc/apk/repositories"
"$tmp/apk/sbin/apk.static" --root "$tmp/root" --keys-dir "$tmp/root/etc/apk/keys" \
	--no-interactive --no-scripts add wine
rm -rf "$dir" && mkdir -p "$(dirname "$dir")" && mv "$tmp/root" "$dir" && rm -rf "$tmp"
echo "linux/wine-amd64: $(ls "$dir/usr/lib/wine")"
