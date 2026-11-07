#!/usr/bin/env bash
# Fetches reference sources, the pinned 9front arm64 image, prebuilt Unicorn
# libraries and the patched Unicorn source into .local.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$H9_ROOT/scripts/pins.sh"

mkdir -p "$H9_LOCAL"/{bin,src,cache,9front,unicorn}

# clone repo dir [rev]: a shallow clone at rev, or tracking the default
# branch if rev is empty.
clone() {
	local repo=$1 dir="$H9_LOCAL/src/$2" rev=${3:-}
	if [ -n "$rev" ]; then
		[ -d "$dir/.git" ] || git init -q "$dir"
		if [ "$(git -C "$dir" rev-parse -q --verify HEAD || true)" != "$rev" ]; then
			git -C "$dir" fetch -q --depth 1 "$repo" "$rev"
			git -C "$dir" checkout -q --detach "$rev"
		fi
	elif [ -d "$dir/.git" ]; then
		git -C "$dir" pull -q --ff-only
	else
		git clone -q --depth 1 "$repo" "$dir"
	fi
	echo "src/$2: $(git -C "$dir" rev-parse --short HEAD)"
}

clone "$HYPERLINUX_REPO" hyper-linux
clone "$NINEFRONT_REPO" 9front "$NINEFRONT_REV"

img="9front-$NINEFRONT_RELEASE.arm64.qcow2"
if [ ! -f "$H9_LOCAL/9front/$img" ]; then
	curl -fL --progress-bar -o "$H9_LOCAL/9front/$img.gz" "$NINEFRONT_ISO_URL/$img.gz"
	gunzip "$H9_LOCAL/9front/$img.gz"
fi
echo "9front/$img"

# Unicorn: headers and libunicorn.a for each target into .local/unicorn/<name>.
echo "$UNICORN_WHEELS" | while read -r name tag sha; do
	[ -n "$name" ] || continue
	dir="$H9_LOCAL/unicorn/$name"
	if [ ! -f "$dir/lib/libunicorn.a" ]; then
		whl="$H9_LOCAL/cache/unicorn-$UNICORN_VERSION-$tag.whl"
		curl -fsSL -o "$whl" "$UNICORN_WHEEL_URL/unicorn-$UNICORN_VERSION-py2-none-$tag.whl"
		echo "$sha  $whl" | shasum -a 256 -c --quiet
		rm -rf "$dir" "$dir.tmp"
		unzip -q "$whl" 'unicorn/lib/libunicorn.a' 'unicorn/include/*' -d "$dir.tmp"
		mv "$dir.tmp/unicorn" "$dir"
		rm -rf "$dir.tmp" "$whl"
	fi
	echo "unicorn/$name: $UNICORN_VERSION"
done

# Unicorn source: unpacked into .local/src/unicorn with our patches applied.
# A stamp holds the tarball hash and the patches' hashes, so it's redone only
# when either changes.
src="$H9_LOCAL/src/unicorn"
patches=("$H9_ROOT"/third_party/unicorn/patches/*.patch)
stamp="$UNICORN_SRC_SHA256 $(cat "${patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
if [ "$(cat "$src/.h9-stamp" 2>/dev/null || true)" != "$stamp" ]; then
	tgz="$H9_LOCAL/cache/unicorn-$UNICORN_VERSION.tar.gz"
	curl -fsSL -o "$tgz" "$UNICORN_SRC_URL"
	echo "$UNICORN_SRC_SHA256  $tgz" | shasum -a 256 -c --quiet
	rm -rf "$src" "$src.tmp" && mkdir -p "$src.tmp"
	tar -xzf "$tgz" -C "$src.tmp" --strip-components 1
	for p in "${patches[@]}"; do
		patch -s -p1 -d "$src.tmp" <"$p" || { echo "fetch: $p doesn't apply" >&2; exit 1; }
	done
	echo "$stamp" >"$src.tmp/.h9-stamp"
	mv "$src.tmp" "$src"
	rm -f "$tgz"
fi
echo "src/unicorn: $UNICORN_VERSION + ${#patches[@]} patches"

# v86: v86.wasm and its license into .local/v86, for zig build web.
dir="$H9_LOCAL/v86"
if [ "$(cat "$dir/.h9-stamp" 2>/dev/null || true)" != "$V86_SHA256" ]; then
	tgz="$H9_LOCAL/cache/v86-$V86_VERSION.tgz"
	curl -fsSL -o "$tgz" "$V86_URL"
	echo "$V86_SHA256  $tgz" | shasum -a 256 -c --quiet
	rm -rf "$dir" "$dir.tmp" && mkdir -p "$dir.tmp"
	tar -xzf "$tgz" -C "$dir.tmp" --strip-components 1 package/build/v86.wasm package/LICENSE
	mv "$dir.tmp/build/v86.wasm" "$dir.tmp/v86.wasm" && rmdir "$dir.tmp/build"
	echo "$V86_WASM_SHA256  $dir.tmp/v86.wasm" | shasum -a 256 -c --quiet
	echo "$V86_SHA256" >"$dir.tmp/.h9-stamp"
	mv "$dir.tmp" "$dir"
	rm -f "$tgz"
fi
echo "v86: $V86_VERSION"
