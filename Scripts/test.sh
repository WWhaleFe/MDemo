#!/bin/bash
# 전 패키지 테스트 실행.
#
# Xcode가 없거나 라이선스 미동의 상태에서도 동작하도록
# .testTarget 대신 실행 가능한 러너를 쓴다 (Packages/TestKit 참고).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"

FAILED=0
for package in MemoCore MarkdownEngine Services; do
    if ! (cd "$ROOT/Packages/$package" && swift run -c debug "${package}Tests" 2>&1 \
        | grep -vE "^\[|Compiling|Emitting|Build |Planning|Write |Linking|Building for"); then
        FAILED=1
    fi
done

if [ $FAILED -eq 0 ]; then
    echo "✓ 전체 테스트 통과"
else
    echo "✗ 실패한 테스트가 있습니다"
    exit 1
fi
