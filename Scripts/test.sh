#!/bin/bash
# 전 패키지 테스트 실행.
#
# Xcode가 없거나 라이선스 미동의 상태에서도 동작하도록
# .testTarget 대신 실행 가능한 러너를 쓴다 (Packages/TestKit 참고).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"

# 패키지마다 따로 빌드 폴더를 쓰면, 아래 계층에 파일을 새로 추가했을 때
# 위 계층이 예전 모듈을 그대로 붙들어 "방금 만든 타입을 찾을 수 없다"는 오류가 난다.
# 한 곳을 함께 쓰면 그런 어긋남이 생기지 않는다.
# 외장 볼륨의 Foundation 원자적 쓰기는 볼륨 루트 권한을 요구하므로 빌드만 임시 경로에 둔다.
BUILD_KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c 1-12)"
SCRATCH="${TMPDIR:-/tmp}/mdemo-swift-$BUILD_KEY"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

# Foundation 설정 저장도 실제 홈 대신 임시 홈에 둔다.
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-test-home.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
export CFFIXED_USER_HOME="$TEST_HOME"

FAILED=0
if ! (cd "$ROOT/core" && cargo test --locked --workspace); then
    FAILED=1
fi
for package in CoreBridge MemoCore MarkdownEngine EditorKit StickyWindow Services Features; do
    if ! (cd "$ROOT/Packages/$package" && swift run -c debug --scratch-path "$SCRATCH" "${package}Tests" 2>&1 \
        | grep -vE "^\[|Compiling|Emitting|Build |Planning|Write |Linking|Building for"); then
        FAILED=1
    fi
done

# 한 패키지가 실패해도 골든 비교까지 실행해 차이를 함께 보고한다.
if ! "$ROOT/Scripts/golden-check.sh" swift; then
    FAILED=1
fi

if ! "$ROOT/Scripts/golden-check.sh" rust; then
    FAILED=1
fi

# 같은 연산 시나리오를 두 구현으로 돌려 데이터 폴더를 비교한다.
if ! "$ROOT/Scripts/scenario-check.sh"; then
    FAILED=1
fi

# 암호 메모 교차 검사(빠른 시나리오). 전체는 make lock-full.
if ! "$ROOT/Scripts/lock-check.sh" quick; then
    FAILED=1
fi

# 동기화와 백업 교차 검사(P6).
if ! "$ROOT/Scripts/sync-check.sh" quick; then
    FAILED=1
fi
if ! "$ROOT/Scripts/backup-check.sh"; then
    FAILED=1
fi

if [ $FAILED -eq 0 ]; then
    echo "✓ 전체 테스트 통과"
else
    echo "✗ 실패한 테스트가 있습니다"
    exit 1
fi
