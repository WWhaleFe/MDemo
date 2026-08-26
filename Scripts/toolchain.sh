#!/bin/bash
# 사용 가능한 Swift 툴체인을 고른다. 다른 스크립트에서 source 해서 쓴다.
#
# Xcode를 설치하면 활성 개발자 디렉터리가 Xcode로 바뀌는데,
# 라이선스에 동의하기 전까지는 swift/xcrun이 전부 막힌다.
# 그 상태에서도 개발이 멈추지 않도록 Command Line Tools로 되돌린다.

if ! swift --version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    echo "⚠ 활성 Xcode 툴체인을 쓸 수 없어 Command Line Tools로 진행합니다."
    echo "  Xcode 툴체인을 쓰려면 터미널에서 한 번만 실행하세요:"
    echo "    sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch"
fi
