#!/bin/bash
# 계층 규칙 검사 (설계서 §7-4).
#
# MemoCore · MarkdownEngine · Services 는 UI 프레임워크에 의존하면 안 된다.
# 이 규칙이 깨지면 iOS 확장(SYNC-11)이 불가능해지고, 순수 로직 테스트도 어려워진다.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS=0

for package in CoreBridge MemoCore MarkdownEngine Services; do
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
# 예외는 업데이트 확인(파일 하나), 구글 드라이브 통신(GoogleDrive 폴더의 두 파일), 노션 통신(Notion 폴더의 파일 하나)뿐이다.
NET_HITS="$(grep -rn --include='*.swift' -E 'URLSession|NWConnection|NWListener|CFStream' \
    "$ROOT/Packages" "$ROOT/App" 2>/dev/null \
    | grep -v '/App/Sources/MDemo/Update/UpdateChecker.swift:' \
    | grep -v '/Packages/Services/Sources/Services/GoogleDrive/GoogleHTTP.swift:' \
    | grep -v '/Packages/Services/Sources/Services/GoogleDrive/LoopbackReceiver.swift:' \
    | grep -v '/Packages/Services/Sources/Services/Notion/NotionHTTP.swift:' || true)"
if [ -n "$NET_HITS" ]; then
    echo "✗ 네트워크 통신 코드가 발견되었습니다 (NFR-07 위반):"
    echo "$NET_HITS"
    STATUS=1
else
    echo "✓ 네트워크 통신 코드 없음 (NFR-07, 업데이트 확인 · 구글 드라이브 · 노션 통신 제외)"
fi

# C 모듈은 CoreBridge만, CoreBridge는 화면 아래 계층만 참조한다.
FFI_HITS="$(grep -rEn --include='*.swift' '^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*((public|internal|private|fileprivate|package)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?MDemoCoreFFI([.[:space:]]|$)' "$ROOT/Packages" "$ROOT/App" | grep -v '/Packages/CoreBridge/' || true)"
BRIDGE_HITS="$(grep -rEn --include='*.swift' '^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*((public|internal|private|fileprivate|package)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?CoreBridge([.[:space:]]|$)' "$ROOT/Packages/Features" "$ROOT/Packages/StickyWindow" "$ROOT/Packages/EditorKit" "$ROOT/App" || true)"
if [ -n "$FFI_HITS$BRIDGE_HITS" ]; then
    echo "✗ Rust 경계 계층 규칙 위반:"
    echo "$FFI_HITS$BRIDGE_HITS"
    STATUS=1
else
    echo "✓ Rust 경계 계층 규칙 통과"
fi

# 화면 설정은 AppSettings.defaults를 거친다. 그래야 --data-dir 시험 실행이 실제 앱 설정을 바꾸지 않는다.
STORE_HITS="$(grep -rn --include='*.swift' '@AppStorage(' "$ROOT/Packages" "$ROOT/App" | grep -v 'store: AppSettings.defaults' || true)"
if [ -n "$STORE_HITS" ]; then
    echo "✗ @AppStorage가 AppSettings.defaults를 쓰지 않습니다 (시험 실행이 실제 설정을 바꿀 수 있음):"
    echo "$STORE_HITS"
    STATUS=1
else
    echo "✓ 화면 설정 저장소 규칙 통과"
fi

exit $STATUS
