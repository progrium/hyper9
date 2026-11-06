# Pinned upstream versions. Bump deliberately.
DRAWTERM_REPO=https://github.com/9front/drawterm
DRAWTERM_REV=be39bbaa88fda83bf75be642d093b20956297c8c

NINEFRONT_REPO=https://github.com/9front/9front
NINEFRONT_RELEASE=11952 # "THIS WAS SUPPOSED TO BE FUN", Aug 2026
# The release's source: HEAD of /dist/9front in the release image.
NINEFRONT_REV=602faae9a52f342a40b086d10b23c71c82dd52d7
NINEFRONT_ISO_URL=https://9front.org/iso

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
