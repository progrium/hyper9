#!/usr/bin/env bash
# Builds release assets into dist/<version>/ for a GitHub release:
#
#   h9-<version>-<target>.tar.gz|zip      MIT: h9 without the emulator
#   h9-emu-<version>-<target>.tar.gz|zip  GPLv2: h9 with Unicorn (-Demu=unicorn)
#   h9-emu-<version>-source.tar.gz        complete corresponding source for h9-emu
#   SHA256SUMS
#
# Every binary is built from the unpacked source tarball, not the checkout,
# so the tarball is exactly the source of what ships. Unicorn is always built
# from source (-Dunicorn=source), never from the prebuilt wheels.
#
#   scripts/release.sh [version]    (default: git describe --tags --always)
#
# Needs a clean checkout (tracked files) and the patched Unicorn source from
# scripts/fetch.sh. Runs on macOS, which can build every target.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$H9_ROOT/scripts/pins.sh"
cd "$H9_ROOT"

# Targets for each asset. h9 has a hypervisor backend only on macOS until
# KVM and WHP are built (design/kvm.md, design/whp.md); h9-emu runs
# everywhere Unicorn builds.
H9_TARGETS="aarch64-macos"
EMU_TARGETS="aarch64-macos aarch64-linux-musl x86_64-linux-musl aarch64-windows-gnu"

die() { echo "release: $*" >&2; exit 1; }

version=${1:-$(git describe --tags --always)}
[ -z "$(git status --porcelain --untracked-files=no)" ] ||
	die "uncommitted changes; release from a clean checkout"

# Same stamp as fetch.sh: the source must match the pins and the patches.
uc_src="$H9_LOCAL/src/unicorn"
patches=("$H9_ROOT"/third_party/unicorn/patches/*.patch)
stamp="$UNICORN_SRC_SHA256 $(cat "${patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
[ "$(cat "$uc_src/.h9-stamp" 2>/dev/null || true)" = "$stamp" ] ||
	die "$uc_src is missing or stale; run scripts/fetch.sh"

out="$H9_ROOT/dist/$version"
work="$out/.work"
rm -rf "$out" && mkdir -p "$work"

# Source: the commit, plus Unicorn's patched source where build/unicorn.zig
# expects it, so `zig build -Demu=unicorn -Dunicorn=source` works offline.
srcname="h9-emu-$version-source"
src="$work/$srcname"
mkdir -p "$src"
git archive HEAD | tar -x -C "$src"
mkdir -p "$src/.local/src/unicorn"
cp -R "$uc_src/." "$src/.local/src/unicorn/"
cat >"$src/SOURCE" <<EOF
Complete corresponding source for h9-emu $version
(h9 commit $(git rev-parse HEAD)).

- h9's source (MIT, see LICENSE), with the patches to Unicorn and QEMU's
  generated config headers in third_party/unicorn (GPLv2, see
  third_party/unicorn/COPYING).
- Unicorn Engine $UNICORN_VERSION ($UNICORN_SRC_URL,
  sha256 $UNICORN_SRC_SHA256) in .local/src/unicorn, with
  third_party/unicorn/patches already applied. Its own licence files
  (COPYING, COPYING.LGPL2, COPYING_GLIB, qemu/LICENSE) are in that directory.

Build with Zig $(zig version) (see README.md); for example:

  zig build -Doptimize=ReleaseSafe -Demu=unicorn -Dunicorn=source -Dversion=$version -Dtarget=aarch64-linux-musl

then rename zig-out/bin/h9 to h9-emu. Targets: $EMU_TARGETS.
EOF
tar -czf "$out/$srcname.tar.gz" -C "$work" "$srcname"

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

for t in $EMU_TARGETS; do
	name="h9-emu-$version-$t"
	build "$work/build-emu-$t" "$t" -Demu=unicorn -Dunicorn=source
	mkdir -p "$work/$name"
	cp "$work/build-emu-$t/bin/$(exe "$t" h9)" "$work/$name/$(exe "$t" h9-emu)"
	cp "$src/third_party/unicorn/COPYING" "$work/$name/COPYING"
	cp "$src/LICENSE" "$work/$name/LICENSE.h9"
	cp "$src/third_party/drawterm/LICENSE" "$work/$name/LICENSE.drawterm"
	cat >"$work/$name/NOTICE" <<EOF
h9-emu is h9 built with the Unicorn Engine emulator backend.

It includes Unicorn Engine $UNICORN_VERSION (https://www.unicorn-engine.org),
which is based on QEMU, with h9's patches to it. The combined program is
distributed under the GNU General Public License version 2; see COPYING.

h9's own code is also available under the MIT license (LICENSE.h9), and
drawterm's under its MIT license (LICENSE.drawterm).

Complete corresponding source, including Unicorn's and QEMU's per-file
licences: $srcname.tar.gz, attached to the same release at
https://github.com/progrium/hp9/releases/tag/$version
EOF
	archive "$work/$name" "$name"
done

rm -rf "$work"
(cd "$out" && shasum -a 256 h9-* >SHA256SUMS)
echo "release: $out"
ls -1 "$out"
