# Pinned upstream versions. Bump deliberately.
DRAWTERM_REPO=https://github.com/9front/drawterm
DRAWTERM_REV=be39bbaa88fda83bf75be642d093b20956297c8c

NINEFRONT_REPO=https://github.com/9front/9front
NINEFRONT_RELEASE=11952 # "THIS WAS SUPPOSED TO BE FUN", Aug 2026
# The release's source: HEAD of /dist/9front in the release image.
NINEFRONT_REV=602faae9a52f342a40b086d10b23c71c82dd52d7
NINEFRONT_ISO_URL=https://9front.org/iso
# The release's 386 ISO, unpacked (zig build isoroot) into the 386 root
# the Pages workflow packs the browser host's demo archive from. The hash
# is of the ISO after gunzip.
NINEFRONT_386_ISO_SHA256=068e8ff723a3e5b8c6fdec4862f53e0b7d04e04b3b54baca022b9d2fe869035f

HYPERLINUX_REPO=https://github.com/zw3rk/hyper-linux

# Go for the go-compat fixtures and go-stdtest (design/0007-go-compat.md):
# GOTOOLCHAIN=go$GO_VERSION makes any installed Go fetch this exact release.
GO_VERSION=1.27.3

# Prebuilt static Unicorn for the emu backend (-Demu=unicorn), taken from the
# PyPI wheels. GPLv2: dev and CI builds only. No Windows arm64 wheel exists.
UNICORN_VERSION=2.1.4
UNICORN_WHEEL_URL=https://files.pythonhosted.org/packages/py2/u/unicorn
# name  wheel-platform-tag  sha256
UNICORN_WHEELS="
aarch64-macos macosx_11_0_arm64 8a7a94e67ce277c63112afa06640862b6c7395b8d42aec38f7a61a96c4b1658e
aarch64-linux-musl musllinux_1_2_aarch64 35ac021ead8c992b15a511be73bf703429e5d346136ae38e6307c3d852655341
x86_64-linux-musl musllinux_1_2_x86_64 73d2eb557cc0255f18c55b15951c46dff1c07f996588df4cea1b1bdc5d69b184
"
# Unicorn source, for building it with Zig (build/unicorn.zig): fetch.sh
# unpacks it into .local/src/unicorn and applies third_party/unicorn/patches.
# Same version as the wheels. GPLv2: dev, CI and the h9-emu release.
UNICORN_SRC_URL=https://github.com/unicorn-engine/unicorn/archive/refs/tags/$UNICORN_VERSION.tar.gz
UNICORN_SRC_SHA256=ea8863f095a0136388694e5a6063afd9bb7650e30243dd6251af59c5ce5601f4

# An Alpine root for the Linux personality's tests (design/0018-linux-personality.md):
# the alpine:3.22.2 image's single layer from Docker Hub, by digest, unpacked
# into .local/linux/alpine-<arch>.
ALPINE_VERSION=3.22.2
ALPINE_REGISTRY=https://registry-1.docker.io
# arch  layer-digest (sha256 of the gzipped tarball)
ALPINE_LAYERS="
arm64 6b59a28fa20117e6048ad0616b8d8c901877ef15ff4c7f18db04e4f01f43bc39
amd64 2d35ebdb57d9971fea0cac1582aa78935adf8058b2cc32db163c98822e5dfa1b
386 13c6e95c06ae06f126f5e940d6d88c2fec0da715c80878ad225c76ad48d0a31e
"

# Alpine 3.22's x86 packages for the browser host's Linux demo
# (src/web/linux.list), added to a copy of the 386 root as
# .local/linux/alpine-386-web by `scripts/fetch.sh alpine386web`. Alpine's
# mirrors keep only each package's newest build, so a bump there means a
# bump here.
ALPINE_PKG_URL=https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86
# package-file  sha256
ALPINE_386_WEB_PKGS="
jq-1.8.2-r0.apk 8c1723d8cd568238307d7769fd777c7e82b48b875e205ac20f985a24e98f77ed
oniguruma-6.9.10-r0.apk 81f950d14be98a5a3bf2d7eead3125cf8be00ed32e9d1110643240c4fb671b58
sqlite-3.49.2-r1.apk 0011331af45374074dc23bfa5c068af78bcdbc9ad283f49e5e8cb8a5890cf54b
readline-8.2.13-r1.apk 29e35b5876481d0d1d4f60fdfdbd59a0c974d86e6355f7c38ea85518645ada6b
libncursesw-6.5_p20250503-r0.apk b1262e30c3eb0c9a9b74dba4f33c36ca37e33c4a060429af22f371236bfd4d61
"
