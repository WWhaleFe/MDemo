#!/bin/bash
# 입력 규칙 지연 측정(P7): 대표 줄 200개 x 1,000회를 Swift 직접 호출과 Rust FFI 왕복으로 재어 비교한다.
# 릴리스 빌드로 잰다. 결과(표)는 docs/measurements.md에 옮겨 적는다. 끝나면 디버그 산출물로 되돌린다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
BUILD_KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c 1-12)"
SCRATCH="${TMPDIR:-/tmp}/mdemo-swift-$BUILD_KEY"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-measure-home.XXXXXX")"
trap 'rm -rf "$TEST_HOME"; "$ROOT/Scripts/build-core.sh" debug >/dev/null' EXIT
export CFFIXED_USER_HOME="$TEST_HOME"
"$ROOT/Scripts/build-core.sh" release
cd "$ROOT/Packages/MemoCore"
MDEMO_MEASURE=1 swift run -c release --scratch-path "$SCRATCH" MemoCoreTests --markdown-tests-only "$@" 2>&1 | grep -E "MEASURE|PARSE|✓|✗|통과|실패"
echo "측정 환경: $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productName) $(sw_vers -productVersion)"
