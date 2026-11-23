#!/usr/bin/env bash
# Builds release assets into dist/<version>/ for a GitHub release:
#
#   h9-<version>-<target>.tar.gz|zip      MIT: h9, with hcpu, h9's own CPUs,
#                                         as the emulator backend
#   h9-web-<version>.tar.gz               MIT: the browser host
#                                         (h9.wasm, h9-web.js, h9-node,
#                                         the demo page and its root archive)
#   SHA256SUMS
#
# Every binary is built from an unpacked `git archive` of HEAD, not the
# checkout, so what ships is exactly the commit. There's one licence:
# hcpu, always built in, is the emulator and there is no h9-emu
# (design/hcpu.md).
#
#   scripts/release.sh [version]    (default: git describe --tags --always)
#
# Needs a clean checkout (tracked files). The browser host's root archive
# comes from the 386 root tree (scripts/mkroot.py --arch 386), when there
# is one. Runs on macOS, which can build every target.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$H9_ROOT/scripts/pins.sh"
cd "$H9_ROOT"

# Targets for h9. Each runs on its host's hypervisor where there is one,
# and on hcpu where there isn't.
H9_TARGETS="aarch64-macos aarch64-linux-musl x86_64-linux-musl aarch64-windows-gnu x86_64-windows-gnu"

die() { echo "release: $*" >&2; exit 1; }

version=${1:-$(git describe --tags --always)}
[ -z "$(git status --porcelain --untracked-files=no)" ] ||
	die "uncommitted changes; release from a clean checkout"

out="$H9_ROOT/dist/$version"
work="$out/.work"
rm -rf "$out" && mkdir -p "$work"

src="$work/h9-$version-source"
mkdir -p "$src"
git archive HEAD | tar -x -C "$src"

# build <prefix> <target> [flags...]: builds h9 from the source tree.
build() {
	local prefix=$1 target=$2
	shift 2
	(cd "$src" && zig build -p "$prefix" -Doptimize=ReleaseSafe -Dtarget="$target" -Dversion="$version" "$@")
}

# archive <dir> <name>: dist/<name>.zip for Windows, else .tar.gz.
archive() {
	local dir=$1 name=$2
	case "$name" in
	*windows*) (cd "$(dirname "$dir")" && zip -qr "$out/$name.zip" "$(basename "$dir")") ;;
	*) tar -czf "$out/$name.tar.gz" -C "$(dirname "$dir")" "$(basename "$dir")" ;;
	esac
}

exe() { case "$1" in *windows*) echo "$2.exe" ;; *) echo "$2" ;; esac; }

for t in $H9_TARGETS; do
	name="h9-$version-$t"
	build "$work/build-$t" "$t"
	mkdir -p "$work/$name"
	cp "$work/build-$t/bin/$(exe "$t" h9)" "$work/$name/"
	cp "$src/LICENSE" "$work/$name/LICENSE"
	cp "$src/third_party/drawterm/LICENSE" "$work/$name/LICENSE.drawterm"
	archive "$work/$name" "$name"
done

# The browser host (design/epoch-0/browser-host.md): one archive for every
# platform.
name="h9-web-$version"
web_root=()
[ -f "$H9_LOCAL/9front/root386/386/bin/rc" ] && web_root=(-Dweb-root="$H9_LOCAL/9front/root386")
(cd "$src" && zig build web -p "$work/build-web" -Doptimize=ReleaseSafe -Dversion="$version" "${web_root[@]}")
cp -R "$work/build-web/web" "$work/$name"
cp "$src/LICENSE" "$work/$name/LICENSE"
cp "$src/third_party/drawterm/LICENSE" "$work/$name/LICENSE.drawterm"
archive "$work/$name" "$name"

rm -rf "$work"
(cd "$out" && shasum -a 256 h9-* >SHA256SUMS)
echo "release: $out"
ls -1 "$out"
