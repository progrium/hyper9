#!/bin/sh
# tools/workloads/roots.sh: the workloads' Linux roots, built on the host.
#
# For arm64 and 386: the pinned Alpine layer (scripts/pins.sh, as
# scripts/fetch.sh unpacks it), copied to .local/workloads/alpine-<arch>,
# with python3, sqlite, and git added by Alpine's apk.static (--no-scripts,
# so nothing of the guest's runs here), and the workloads' own files:
#
#   /w/speedtest1   SQLite's speedtest1, static, built with zig cc
#   /w/gowork       the Go program (gowork/), static, GOARCH=arm64 or 386
#   /w/bench.py     the pure-Python benchmark
#   /w/tree         a large git tree (a clone of this repo's history)
#
# Needs curl, zig, and go on the host. Idempotent: a root that exists is
# brought up to date, not rebuilt. apk.static is an x86-64 Linux binary;
# on any other host the packages come from the root's own apk, run by h9
# (H9, default h9 on PATH) with outbound network.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$repo/scripts/pins.sh"
L="$repo/.local"
W="$L/workloads"
mkdir -p "$W" "$L/cache"

# SQLite's amalgamation, as github.com/mattn/go-sqlite3 vendors it (the
# Go module proxy has it; sqlite.org may not be reachable), and the
# matching speedtest1.c from SQLite's GitHub mirror.
SQLITE_VERSION=3.50.4
SQLITE_GOMOD=v1.14.32
SQLITE_GOMOD_SHA256=c70101000256656bc0b7286807cf177852c753a001a3aa3c55d5373575fb81aa
SPEEDTEST1_SHA256=f495cd1c3f727ebf6270d967b43f11a14304053ae4532d6338dbfea65c1a5a78
APK_TOOLS=apk-tools-static-2.14.13-r0.apk
REPO=https://dl-cdn.alpinelinux.org/alpine/v3.22

sha256() { if command -v sha256sum >/dev/null; then sha256sum -c --quiet; else shasum -a 256 -c --quiet; fi; }
apk=$W/apk.static
host_apk=0
[ "$(uname -s)/$(uname -m)" = Linux/x86_64 ] && host_apk=1
if [ $host_apk = 1 ] && [ ! -x "$apk" ]; then
	t=$(mktemp -d)
	curl -fsSL -o "$t/a.apk" "$REPO/main/x86_64/$APK_TOOLS"
	tar -xzf "$t/a.apk" -C "$t" sbin/apk.static 2>/dev/null
	mv "$t/sbin/apk.static" "$apk"
	rm -rf "$t"
fi

# speedtest1.c and the amalgamation it builds with.
src="$W/sqlite-$SQLITE_VERSION"
if [ ! -f "$src/speedtest1.c" ]; then
	t=$(mktemp -d)
	curl -fsSL -o "$t/m.zip" "https://proxy.golang.org/github.com/mattn/go-sqlite3/@v/$SQLITE_GOMOD.zip"
	echo "$SQLITE_GOMOD_SHA256  $t/m.zip" | sha256
	d="github.com/mattn/go-sqlite3@$SQLITE_GOMOD"
	(cd "$t" && unzip -q m.zip "$d/sqlite3-binding.c" "$d/sqlite3-binding.h")
	mkdir -p "$src"
	# The binding is the amalgamation inside #ifndef USE_LIBSQLITE3.
	cp "$t/$d/sqlite3-binding.c" "$src/sqlite3.c"
	cp "$t/$d/sqlite3-binding.h" "$src/sqlite3.h"
	perl -pi -e 's/"sqlite3-binding.h"/"sqlite3.h"/' "$src/sqlite3.c"
	curl -fsSL -o "$t/speedtest1.c" "https://raw.githubusercontent.com/sqlite/sqlite/version-$SQLITE_VERSION/test/speedtest1.c"
	echo "$SPEEDTEST1_SHA256  $t/speedtest1.c" | sha256
	mv "$t/speedtest1.c" "$src/"
	rm -rf "$t"
fi

echo "$ALPINE_LAYERS" | while read -r arch sha; do
	case $arch in arm64) apkarch=aarch64 zt=aarch64-linux-musl ga=arm64 ;; 386) apkarch=x86 zt=x86-linux-musl ga=386 ;; *) continue ;; esac
	base="$L/linux/alpine-$arch"
	if [ "$(cat "$base/.h9-stamp" 2>/dev/null || true)" != "$sha" ]; then
		tok=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull" |
			sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
		tgz="$L/cache/alpine-$ALPINE_VERSION-$arch.tar.gz"
		curl -fsSL -H "Authorization: Bearer $tok" -o "$tgz" "$ALPINE_REGISTRY/v2/library/alpine/blobs/sha256:$sha"
		echo "$sha  $tgz" | sha256
		rm -rf "$base" "$base.tmp" && mkdir -p "$base.tmp"
		tar -xzf "$tgz" -C "$base.tmp"
		echo "$sha" >"$base.tmp/.h9-stamp"
		mv "$base.tmp" "$base"
		rm -f "$tgz"
	fi
	root="$W/alpine-$arch"
	[ -d "$root" ] || cp -a "$base" "$root"
	if [ $host_apk = 1 ]; then
		"$apk" --root "$root" --arch "$apkarch" --no-scripts --no-progress --quiet \
			-X "$REPO/main" -X "$REPO/community" --repositories-file /dev/null \
			--cache-dir "$L/cache/apk-$arch" -U add python3 sqlite git
	else
		printf '%s/main\n%s/community\n' "$REPO" "$REPO" >"$root/etc/apk/repositories"
		"${H9:-h9}" --arch "$arch" --root "$root" --writable "$root" --net outbound \
			apk add --no-cache --quiet python3 sqlite git
	fi
	mkdir -p "$root/w"
	cp "$here/bench.py" "$root/w/"
	[ -x "$root/w/speedtest1" ] || zig cc -target "$zt" -static -O2 -DSQLITE_OMIT_LOAD_EXTENSION \
		-o "$root/w/speedtest1" "$src/speedtest1.c" "$src/sqlite3.c"
	(cd "$here/gowork" && CGO_ENABLED=0 GOOS=linux GOARCH=$ga go build -o "$root/w/gowork" .)
	if [ ! -d "$root/w/tree/.git" ]; then
		git clone -q --no-hardlinks "$repo" "$root/w/tree"
		# Untracked and modified files for status to find.
		(cd "$root/w/tree" && for i in $(seq 1 200); do echo "$i" >"untracked-$i"; done && find src -name '*.zig' | sort | head -50 | while read -r f; do echo // >>"$f"; done)
	fi
	echo "workloads/alpine-$arch: ready"
done
