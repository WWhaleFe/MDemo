#!/bin/bash
# SwiftPM 실행 파일을 macOS .app 번들로 조립한다.
# Xcode 없이 Command Line Tools만으로 동작한다.
#
# 사용법: Scripts/bundle.sh [debug|release]
#   debug   : 현재 아키텍처만 빌드 (개발용, 빠름)
#   release : arm64 + x86_64 유니버설 빌드 (배포용)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
PRODUCT_NAME="MDemo"
APP_NAME="MDemo"
APP_DIR="$ROOT/build/$APP_NAME.app"

cd "$ROOT"

# 테스트와 같은 빌드 폴더를 쓴다. 따로 두면 아래 계층에 파일을 추가했을 때
# 한쪽이 예전 모듈을 붙들어 "방금 만든 타입을 찾을 수 없다"는 오류가 난다.
SCRATCH="$ROOT/.build-shared"

if [ "$CONFIG" = "release" ]; then
    BUILD_FLAGS=(-c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH")
else
    BUILD_FLAGS=(-c debug --scratch-path "$SCRATCH")
fi

echo "▸ 빌드 중 ($CONFIG)…"
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "▸ 번들 조립 중…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH/$PRODUCT_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/App/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# 앱 아이콘. 원본 PNG를 바꿨다면 Scripts/make-icon.sh로 다시 만든다.
cp "$ROOT/App/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# 시스템 메뉴와 컨트롤이 앱 강조색을 찾도록 에셋 카탈로그를 번들에 넣는다.
# actool은 Xcode에 포함되므로 Command Line Tools만 있을 때는 생략한다.
if xcrun --find actool >/dev/null 2>&1; then
    echo "▸ 색상 에셋 컴파일 중…"
    xcrun actool "$ROOT/App/Resources/Assets.xcassets" \
        --compile "$APP_DIR/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0
else
    echo "⚠ actool을 찾을 수 없어 앱 강조색 에셋 컴파일을 생략합니다."
fi

# 유료 개발자 계정이 없으므로 임시(ad-hoc) 서명을 쓴다.
# 계정을 확보하면 Developer ID 서명 + 공증으로 이 줄만 바꾸면 된다.
echo "▸ 서명 중 (ad-hoc)…"
codesign --force --sign - "$APP_DIR" 2>/dev/null

SIZE="$(du -sh "$APP_DIR" | cut -f1)"
echo "✓ 완료: $APP_DIR  (번들 크기 $SIZE / 목표 30MB 이하)"
