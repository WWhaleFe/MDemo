#!/bin/bash
# 배포 파일을 만든다. GitHub 릴리스에 올릴 .zip과, 끌어서 설치하는 .dmg.
#
# 사용법: Scripts/package.sh
#
# 버전은 App/Resources/Info.plist 한 곳에서 관리한다.
#   CFBundleShortVersionString : 0.9.0 같은 버전. 릴리스 태그는 v0.9.0이 된다.
#   CFBundleVersion            : 빌드 번호. 릴리스할 때마다 1씩 올린다.
# 앱의 업데이트 확인은 GitHub의 최신 릴리스 태그와 이 버전을 비교하고, 릴리스의 .zip을 내려받는다.
#
# 유료 개발자 계정이 없어 임시(ad-hoc) 서명만 한다. 받은 쪽 Mac에서는 Gatekeeper가
# 출처를 확인할 수 없어 처음 실행을 막는다. 한 번 열어 본 뒤
# 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"를 누르면 된다.
# (macOS 15부터는 Finder 우클릭 → "열기"로는 넘어가지 않는다.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MDemo"
APP_DIR="$ROOT/build/$APP_NAME.app"
PLIST="$APP_DIR/Contents/Info.plist"

"$ROOT/Scripts/bundle.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
# 커밋하지 않은 변경이 있으면 이름에 표시한다. 같은 빌드 번호라도 내용이 다를 수 있다는 뜻이다.
DIRTY=""
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    DIRTY="-dirty"
fi

echo "▸ 버전: $VERSION (빌드 $BUILD_NUMBER, $COMMIT$DIRTY)"
codesign --verify --strict "$APP_DIR"

# usagemeter와 같은 이름 꼴. 업데이트 확인이 이 .zip을 찾아 내려받는다.
BASENAME="$APP_NAME-v$VERSION$DIRTY"
DIST="$ROOT/build/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "▸ zip 만드는 중…"
# ditto는 확장 속성과 서명을 지킨 채 묶는다. zip 명령으로 묶으면 서명이 깨질 수 있다.
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST/$BASENAME.zip"

echo "▸ dmg 만드는 중…"
# 앱과 Applications 바로가기를 나란히 둬, 끌어다 놓기만 하면 설치되게 한다.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DIST/$BASENAME.dmg"

echo "✓ 완료"
echo "   앱 : $APP_DIR"
lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME" | sed 's/^/   구조: /'
ls -lh "$DIST" | awk 'NR>1 {print "   " $5 "  " $9}'
