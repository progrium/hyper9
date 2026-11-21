#!/usr/bin/env bash
# Makes an Alpine root with Wine 11 in it, for the wine-draw case in
# tests/backends.zig (design/wine-draw.md) and the web demo's Wine root
# (scripts/wine-web.sh):
#
#   scripts/wine-root.sh [amd64|386]
#
# amd64 (the default) goes to .local/linux/wine-amd64, about 600 MB:
#
#   scripts/wine-root.sh && export H9_TEST_WINE_ROOT=$PWD/.local/linux/wine-amd64
#   zig build wine test
#
# 386 goes to .local/linux/wine-386: 32-bit Wine, which runs on h86 and so
# in the browser. Wine comes from Alpine's own packages, checked against
# the root's signing keys, so its version is the one winedraw targets only
# while Alpine 3.24 ships Wine 11.0 (WINE_VERSION in scripts/pins.sh).
set -euo pipefail
. "$(dirname "$0")/env.sh"

arch=${1:-amd64}
case $arch in
amd64) apkarch=x86_64 ;;
386) apkarch=x86 ;;
*) echo "usage: $0 [amd64|386]" >&2; exit 2 ;;
esac
ALPINE=3.24
MINIROOT=alpine-minirootfs-3.24.4-$apkarch.tar.gz
APK_STATIC=apk-tools-static-3.0.9-r0.apk
MIRROR=https://dl-cdn.alpinelinux.org/alpine

dir="$H9_LOCAL/linux/wine-$arch"
if [ -x "$dir/usr/bin/wine" ]; then
	echo "linux/wine-$arch: present"
	exit 0
fi
tmp="$H9_LOCAL/cache/wine-root-$arch.tmp"
rm -rf "$tmp" && mkdir -p "$tmp/root" "$tmp/apk"
curl -fsSL "$MIRROR/v$ALPINE/releases/$apkarch/$MINIROOT" | tar -xz -C "$tmp/root"
curl -fsSL "$MIRROR/v$ALPINE/main/$apkarch/$APK_STATIC" | tar -xz -C "$tmp/apk" 2>/dev/null
printf '%s\n' "$MIRROR/v$ALPINE/main" "$MIRROR/v$ALPINE/community" >"$tmp/root/etc/apk/repositories"
"$tmp/apk/sbin/apk.static" --root "$tmp/root" --keys-dir "$tmp/root/etc/apk/keys" \
	--no-interactive --no-scripts add wine
rm -rf "$dir" && mkdir -p "$(dirname "$dir")" && mv "$tmp/root" "$dir" && rm -rf "$tmp"
echo "linux/wine-$arch: $(ls "$dir/usr/lib/wine")"
