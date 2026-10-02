#!/bin/bash
# 앱 아이콘(.icns)을 만든다. 원본은 1024×1024 PNG 한 장이면 된다.
#
# 사용법: Scripts/make-icon.sh [원본.png]   (기본: App/Resources/AppIcon.png)
#
# macOS가 쓰는 크기(16 ~ 1024)를 모두 만들어 App/Resources/AppIcon.icns로 묶는다.
# 원본을 바꾼 뒤 이 스크립트를 한 번 돌리고 icns를 함께 커밋한다.
#
# 원본은 캔버스를 꽉 채운 불투명한 정사각 그림이어야 한다. 바깥에 투명한 여백이나
# 둥근 모서리가 있으면 macOS 26은 아이콘을 회색 판 위에 작게 얹어 보여 준다.
# 꽉 찬 그림을 주면 macOS가 자기 틀(둥근 사각형)로 잘라 보여 준다.
# 지금 AppIcon.png는 MDemo_icon.png의 둥근 사각형 안쪽(x 180, y 168, 664×664)을 잘라 키운 것이다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/App/Resources/AppIcon.png}"
OUTPUT="$ROOT/App/Resources/AppIcon.icns"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z $size $size "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "✓ 아이콘: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
