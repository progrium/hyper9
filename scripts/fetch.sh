#!/usr/bin/env bash
# Fetches reference sources, the pinned 9front arm64 image, prebuilt Unicorn
# libraries and the patched Unicorn source into .local, and on request
# the release's 386 ISO, the browser host's Linux demo root, and Wine's
# headers.
#
#   scripts/fetch.sh [part...]   (parts: src image unicorn unicorn-src
#                                 iso386 alpine386web wine; default all but
#                                 iso386, alpine386web and wine)
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$H9_ROOT/scripts/pins.sh"

mkdir -p "$H9_LOCAL"/{bin,src,cache,9front,unicorn}

parts=" ${*:-src image unicorn unicorn-src} "
for p in $parts; do
	case $p in src|image|unicorn|unicorn-src|iso386|alpine386web|wine) ;;
	# v86 was the browser host's 386 CPU before h86; nothing to fetch now.
	v86) ;;
	*) echo "fetch: unknown part '$p'" >&2; exit 2 ;; esac
done
want() { [[ $parts == *" $1 "* ]]; }

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

if want src; then
clone "$HYPERLINUX_REPO" hyper-linux
clone "$NINEFRONT_REPO" 9front "$NINEFRONT_REV"
fi

# Wine's include/ at the pinned release, for zig build wine
# (design/wine-draw.md): a sparse, blobless clone, about 20 MB.
if want wine; then
dir="$H9_LOCAL/src/wine"
if [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$WINE_REV" ]; then
	rm -rf "$dir"
	git clone -q --filter=blob:none --no-checkout --depth 1 --branch "wine-$WINE_VERSION" "$WINE_REPO" "$dir"
	git -C "$dir" sparse-checkout set --no-cone /include/
	git -C "$dir" checkout -q --detach "$WINE_REV"
fi
echo "src/wine: $WINE_VERSION ($(git -C "$dir" rev-parse --short HEAD))"
fi

if want image; then
img="9front-$NINEFRONT_RELEASE.arm64.qcow2"
if [ ! -f "$H9_LOCAL/9front/$img" ]; then
	curl -fL --progress-bar -o "$H9_LOCAL/9front/$img.gz" "$NINEFRONT_ISO_URL/$img.gz"
	gunzip "$H9_LOCAL/9front/$img.gz"
fi
echo "9front/$img"
fi

# The 386 ISO, for zig build isoroot (the Pages workflow's 386 root).
if want iso386; then
iso="9front-$NINEFRONT_RELEASE.386.iso"
if [ ! -f "$H9_LOCAL/9front/$iso" ]; then
	curl -fL --progress-bar -o "$H9_LOCAL/9front/$iso.gz" "$NINEFRONT_ISO_URL/$iso.gz"
	gunzip -c "$H9_LOCAL/9front/$iso.gz" >"$H9_LOCAL/9front/$iso.tmp"
	echo "$NINEFRONT_386_ISO_SHA256  $H9_LOCAL/9front/$iso.tmp" | shasum -a 256 -c --quiet
	mv "$H9_LOCAL/9front/$iso.tmp" "$H9_LOCAL/9front/$iso"
	rm -f "$H9_LOCAL/9front/$iso.gz"
fi
echo "9front/$iso"
fi

# Unicorn: headers and libunicorn.a for each target into .local/unicorn/<name>.
if want unicorn; then
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
fi

# Unicorn source: unpacked into .local/src/unicorn with our patches applied.
# A stamp holds the tarball hash and the patches' hashes, so it's redone only
# when either changes.
if want unicorn-src; then
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
fi

# Alpine roots for the Linux personality's tests: each a layer blob from
# Docker Hub checked against its pinned digest, unpacked once.
mkdir -p "$H9_LOCAL/linux"
echo "$ALPINE_LAYERS" | while read -r arch sha; do
	[ -n "$arch" ] || continue
	dir="$H9_LOCAL/linux/alpine-$arch"
	if [ "$(cat "$dir/.h9-stamp" 2>/dev/null || true)" != "$sha" ]; then
		tok=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull" |
			sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
		tgz="$H9_LOCAL/cache/alpine-$ALPINE_VERSION-$arch.tar.gz"
		curl -fsSL -H "Authorization: Bearer $tok" -o "$tgz" "$ALPINE_REGISTRY/v2/library/alpine/blobs/sha256:$sha"
		echo "$sha  $tgz" | shasum -a 256 -c --quiet
		rm -rf "$dir" "$dir.tmp" && mkdir -p "$dir.tmp"
		tar -xzf "$tgz" -C "$dir.tmp"
		echo "$sha" >"$dir.tmp/.h9-stamp"
		mv "$dir.tmp" "$dir"
		rm -f "$tgz"
	fi
	echo "linux/alpine-$arch: $ALPINE_VERSION"
done

# The browser host's Linux demo root: the 386 Alpine root with the pinned
# packages unpacked over a copy of it, for src/web/linux.list.
if want alpine386web; then
dir="$H9_LOCAL/linux/alpine-386-web"
stamp=$(echo "$ALPINE_386_WEB_PKGS" | shasum -a 256 | cut -d' ' -f1)
if [ "$(cat "$dir/.h9-stamp" 2>/dev/null || true)" != "$stamp" ]; then
	rm -rf "$dir" "$dir.tmp"
	cp -a "$H9_LOCAL/linux/alpine-386" "$dir.tmp"
	echo "$ALPINE_386_WEB_PKGS" | while read -r f sha; do
		[ -n "$f" ] || continue
		apk="$H9_LOCAL/cache/$f"
		curl -fsSL -o "$apk" "$ALPINE_PKG_URL/$f"
		echo "$sha  $apk" | shasum -a 256 -c --quiet
		# An .apk is gzipped tars one after another, which tar reads as
		# one; the signature and .PKGINFO are left out.
		tar -xzf "$apk" -C "$dir.tmp" --exclude='.SIGN.*' --exclude=.PKGINFO
		rm -f "$apk"
	done
	echo "$stamp" >"$dir.tmp/.h9-stamp"
	mv "$dir.tmp" "$dir"
fi
echo "linux/alpine-386-web: $(echo "$ALPINE_386_WEB_PKGS" | awk 'NF{printf "%s ", $1}')"
fi

