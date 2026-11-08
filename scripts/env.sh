# Source this from the repo root: . scripts/env.sh
# bash names the sourced file; other shells (busybox sh, dash) don't, so
# they fall back to the cwd, which the line above asks to be the repo root.
if [ -n "${BASH_SOURCE:-}" ]; then
	H9_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
elif [ -f "$PWD/scripts/env.sh" ]; then
	H9_ROOT=$PWD
else
	echo "env.sh: source it from the repo root (. scripts/env.sh)" >&2
	return 1 2>/dev/null || exit 1
fi
export H9_ROOT
export H9_LOCAL="$H9_ROOT/.local"
export ZIG_GLOBAL_CACHE_DIR="$H9_LOCAL/cache/zig"
export PATH="$H9_ROOT/zig-out/bin:$H9_LOCAL/bin:$PATH"
if [ "$(uname)" = Darwin ] && [ -z "${SDKROOT:-}" ]; then
	SDKROOT=$(xcrun --show-sdk-path 2>/dev/null) && export SDKROOT
fi
