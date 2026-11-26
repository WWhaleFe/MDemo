#!/bin/bash
# Swift 구현의 고정 입력 변환. 생성과 검증이 같은 호출 경로를 쓴다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
# 외장 볼륨의 Foundation 원자적 쓰기는 볼륨 루트 권한을 요구하므로 빌드만 임시 경로에 둔다.
BUILD_KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c 1-12)"
SCRATCH="${TMPDIR:-/tmp}/mdemo-swift-$BUILD_KEY"
if [ "$#" -ne 2 ]; then
    echo "사용법: $0 <입력 폴더> <출력 폴더>" >&2
    exit 2
fi
# 이 래퍼를 직접 호출해도 설정을 실제 홈에서 읽거나 쓰지 않는다.
RUN_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-golden-home.XXXXXX")"
trap 'rm -rf "$RUN_HOME"' EXIT
export CFFIXED_USER_HOME="$RUN_HOME"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift run --disable-sandbox --build-system native --package-path "$ROOT/Packages/Golden" --scratch-path "$SCRATCH" \
    -c debug mdemo-golden "$1" "$2"
