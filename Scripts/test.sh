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
SCRATCH="$ROOT/.build-shared"

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

if [ $FAILED -eq 0 ]; then
    echo "✓ 전체 테스트 통과"
else
    echo "✗ 실패한 테스트가 있습니다"
    exit 1
fi
