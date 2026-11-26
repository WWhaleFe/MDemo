#!/bin/bash
# 교차 검사에서 매 연산마다 SwiftPM을 다시 실행하지 않도록 한 번 빌드한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
BUILD_KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c 1-12)"
SCRATCH="${TMPDIR:-/tmp}/mdemo-swift-$BUILD_KEY"
BUILD_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-build-home.XXXXXX")"
trap 'rm -rf "$BUILD_HOME"' EXIT
export CFFIXED_USER_HOME="$BUILD_HOME"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --package-path "$ROOT/Packages/Golden" --scratch-path "$SCRATCH" -c debug --product mdemo-golden >&2
swift build --package-path "$ROOT/Packages/Golden" --scratch-path "$SCRATCH" -c debug --show-bin-path | while IFS= read -r path; do printf '%s/mdemo-golden\n' "$path"; done
