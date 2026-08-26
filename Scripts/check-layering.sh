#!/bin/bash
# 계층 규칙 검사 (설계서 §7-4).
#
# MemoCore · MarkdownEngine · Services 는 UI 프레임워크에 의존하면 안 된다.
# 이 규칙이 깨지면 iOS 확장(SYNC-11)이 불가능해지고, 순수 로직 테스트도 어려워진다.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS=0

for package in MemoCore MarkdownEngine Services; do
    HITS="$(grep -rn --include='*.swift' -E '^\s*import (AppKit|SwiftUI|UIKit|Cocoa)' \
        "$ROOT/Packages/$package/Sources" 2>/dev/null || true)"
    if [ -n "$HITS" ]; then
        echo "✗ $package 가 UI 프레임워크를 import 했습니다 (계층 규칙 위반):"
        echo "$HITS"
        STATUS=1
    else
        echo "✓ $package : UI 의존성 없음"
    fi
done

# 네트워크 통신 코드가 없어야 한다 (NFR-07).
NET_HITS="$(grep -rn --include='*.swift' -E 'URLSession|NWConnection|CFStream' \
    "$ROOT/Packages" "$ROOT/App" 2>/dev/null || true)"
if [ -n "$NET_HITS" ]; then
    echo "✗ 네트워크 통신 코드가 발견되었습니다 (NFR-07 위반):"
    echo "$NET_HITS"
    STATUS=1
else
    echo "✓ 네트워크 통신 코드 없음 (NFR-07)"
fi

exit $STATUS
