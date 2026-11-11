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
# The release's amd64 ISO, unpacked the same way into the amd64 root CI
# runs the integration cases on (.github/workflows/ci.yml).
NINEFRONT_AMD64_ISO_SHA256=ee90b5e8a8d6b4ee8ad950322f91e338f698dae18c7f5e5800a650bbfa173fd9

HYPERLINUX_REPO=https://github.com/zw3rk/hyper-linux

# Go for the go-compat fixtures and go-stdtest (design/go-compat.md):
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

# An Alpine root for the Linux personality's tests (design/linux-personality.md):
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

# Alpine 3.22's aarch64 packages for the browser host's Linux demo
# (src/web/linux.list), which runs on ha64, h9's own arm64 CPU. They're
# added to a copy of the arm64 root as .local/linux/alpine-arm64-web by
# `scripts/fetch.sh alpinearm64web`. Alpine's mirrors keep only each
# package's newest build, so a bump there means a bump here.
ALPINE_PKG_URL=https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64
# package-file  sha256
ALPINE_ARM64_WEB_PKGS="
jq-1.8.2-r0.apk 20e3b54393eecb2ee3c41a2f54e2401fadadf493b4de58a69fa09fa654c37ab5
oniguruma-6.9.10-r0.apk 486a30ba898571f8f391958494ef3982494dffbc56d368d477293c5159c5c192
sqlite-3.49.2-r1.apk 23cc7ebfee1170d2e6be5740ef5eae1c522691e164e399629f9147705370e8c9
readline-8.2.13-r1.apk 334af29dbf6b5a71a87af4d6a58e2967a8f711a51d00093de0e1498daf83ceb2
libncursesw-6.5_p20250503-r0.apk 419b375e8a4345e7172b1f0f3a3c57db61374f5408cdb875d9e860bd4c243aca
"

# Alpine 3.22's x86_64 packages for the workloads (tests/workloads):
# Python with pip, git, sqlite3, jq, xz, and bash, with the dependencies
# the base image doesn't have. They're added to a copy of the amd64 root
# as .local/linux/workloads-amd64 by `scripts/fetch.sh workloads`. Like
# the web demo's, a bump on the mirror means a bump here.
ALPINE_PKG_BASE=https://dl-cdn.alpinelinux.org/alpine/v3.22
# repository  package-file  sha256
WORKLOADS_AMD64_PKGS="
main python3-3.12.16-r0.apk 4bd1bf5b980cdf906c04a507258cfae8b44b3070d82b7c4cbf77ef2552bbdb06
main libexpat-2.10.0-r0.apk 8ff83a897b5393832edbd2a7500c37bab685a17d7821925d95460f01747dbac2
main libbz2-1.0.8-r6.apk 0c98810f9332bf1bb1b0acc64eaac4b101036689bffba9ea621416b4b3c190cd
main libffi-3.4.8-r0.apk 9a75cb9024693c1e52c3d8d7c9afb7c79e6e20f6c08df28effdb8dd816095083
main gdbm-1.24-r0.apk cb524a457ffbd9c79c6711d9ee883a64a5a9bc6aec4f4b4d047ee67527ac6e6d
main xz-libs-5.8.4-r0.apk 37e169b7b400304fa7027cab79f9c1c7a280e83acf6c95463384b8abb7ebb254
main mpdecimal-4.0.1-r0.apk 28f3d868efbc1e9093b95f4a3f6e74393acd4a37292fcb5c0e0e0612fe83fff3
main libgcc-14.2.0-r6.apk 04f3467bc967e705221a843fe4d3de5850db826e571686e0c0ed453d38cb5c59
main libstdc++-14.2.0-r6.apk 939f7c99898f3e8154207a17f4acbe8bc40437e1bb1b43f5525620ca9e452a2e
main libncursesw-6.5_p20250503-r0.apk aeafdfca68147b014705b4e2564639ade6345198debb522f2c6c51d32e417651
main ncurses-terminfo-base-6.5_p20250503-r0.apk 0815a5f0403974bb9c34d456e71dc9c0222cb5455d393bc63c44b573da3d7fe0
main libpanelw-6.5_p20250503-r0.apk 046257a4535a9ced124595a33053948f6bf8b2f02988fefd1108f514d213ad4b
main readline-8.2.13-r1.apk 520fa586c689144928191bee13e2c85ff4e170ad87d1471ec48e3e97611673d8
main sqlite-libs-3.49.2-r1.apk 7af9a58595642de91ea35d3d070cd38d969680a720ce76b14966859e6fb4af99
main python3-pyc-3.12.16-r0.apk b49968ff0d8e8378709d4ef6ea2e31b2e7b69b24945207b247bb6bf085ee1dce
main python3-pycache-pyc0-3.12.16-r0.apk b1b1732e093d34ce9c1e126fbc013c9299895ed5a09615d088e220e8303e227b
main pyc-3.12.16-r0.apk 3588fbae1376094b8c73f8300bfeb7ff394d17a666d407649f06d9072a3f2094
main git-2.49.1-r0.apk 42f4573799ffce0c7dd4954d2247eb882eb87360dc18637930624484ecfd1c90
main libcurl-8.14.1-r4.apk 3887f3b2e66b513cb0f8211af6369a0ffaf87270c05ed1f18f7313eddc6b3660
main brotli-libs-1.1.1-r0.apk 9e52618457762f65bf273f42d71db8084633a1e9d938ff2611015ba20d44a8cf
main c-ares-1.34.9-r0.apk 9b23aa07901ed64bde0be7ec544f8d2b29de80d996277dc861218c54fff8bc97
main libidn2-2.3.7-r0.apk 515cfe061176c7456ea3548651d0014084d77dd3774b78e2c944404ae75a41ff
main libunistring-1.3-r0.apk 989640e58f7646c0495c3950df36eb7b4df152d8150c2c888f8ab954fed8c908
main nghttp2-libs-1.69.0-r0.apk d6ee515d30d703e94b55ef9c0a02aea053313f654acbd2c655d18e3907ecb66a
main libpsl-0.21.5-r3.apk 1e79da4fa1364b7153b8950a363a6de0bef1d1b48d46fcb3b850cd4f233727b2
main zstd-libs-1.5.7-r0.apk 1bdd6e57cfbfbfd6e8481cad37ddd5d199950715bec1879b3afb600272dbb09e
main pcre2-10.46-r1.apk e0e0e3c5f3b4a37a77799a7367bb40dd38596be55f56f3bc60f2cb4b584f842c
main sqlite-3.49.2-r1.apk 7a2b13ff89bc350b2a04f6977054dbbf48a258eb7c240900028a1ab5b674f010
main jq-1.8.2-r0.apk dc73a46f8a2b0827fb6b0590f07d8f456a41f3fae44e34fe7e3a09b4329325e3
main oniguruma-6.9.10-r0.apk 52f7f6f99840f252d611ded9d72c8ecfdc99888391d6cbc33a7ba6703c271dfe
main xz-5.8.4-r0.apk 3d76841fc8d03c1226969f44f248363acefc13d51e243c34dfbb4b16b35bd2d5
main bash-5.2.37-r0.apk 8218982214f1b51f520d282b0c81d654846e974ce009e758acc6187bd64fe228
community py3-pip-25.1.1-r0.apk 9b17d8a160a41a93ebdd79bb24174788e310d31d07b4642d8416487696053979
main py3-setuptools-80.9.0-r0.apk 53d35a4530371f61481fc800f18f226f68b3600140b851f902764bc91a7273db
main py3-packaging-25.0-r0.apk 06ab1a2853857e1f53da6c4fceaec25ec3c942c24071f6598396d4e18ec68769
main py3-parsing-3.2.5-r0.apk eb98adcfe7a7242b8e4ff77a894e4b8ca3e5a62539c8fa96bc8d07ab9f49c38d
community py3-pip-pyc-25.1.1-r0.apk e729558f32b18993f7dd3461c409e274a7be2c91686a9110e7a931a26ecbc07a
"

# diod, the 9P2000.L server the [dotl] cases run against (design/dotl.md),
# from Ubuntu 24.04's packages with the libraries it links, so no build
# is needed: `scripts/fetch.sh diod` unpacks them into .local/diod, with
# .local/bin/diod running it. x86_64 Linux only; elsewhere those cases
# are skipped. GPLv2: dev and CI only.
DIOD_DEB_URL=http://archive.ubuntu.com/ubuntu/pool
# path  sha256
DIOD_DEBS="
universe/d/diod/diod_1.0.24-5.1_amd64.deb afeca7f1839d5ed0a133aa5b0151b12742faabe516c5ffc3633e73afe0f3a9a0
universe/l/lua5.1/liblua5.1-0_5.1.5-9build2_amd64.deb 2faa6821017f587d016afac1a30e092cc33fcc4ca0afac3349b6523aa8ade5bd
universe/m/munge/libmunge2_0.5.15-4build1_amd64.deb 944e4d5b2c19c7351a3816daf569eda36cbd245102e8d33d178e54e6e560184f
main/t/tcp-wrappers/libwrap0_7.6.q-33_amd64.deb 36118b862539868408ee056411d6e470068d14c46e5296b29bfb744770f5d2ce
"
