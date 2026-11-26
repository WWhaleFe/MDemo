#!/bin/bash
# Rust 맥 라이브러리와 Swift 바인딩을 함께 생성한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "사용법: $0 [debug|release]" >&2; exit 1 ;; esac
export CARGO_NET_OFFLINE="${CARGO_NET_OFFLINE:-false}"
export MACOSX_DEPLOYMENT_TARGET=14.0
OUT="$ROOT/build/core"
GENERATED="$ROOT/Packages/CoreBridge/Sources/CoreBridge/Generated"
mkdir -p "$OUT"
cd "$ROOT"
# 프로필, 도구 버전, 생성 설정도 지문에 넣어 오래된 산출물 재사용을 막는다.
FINGERPRINT="$(
    {
        echo "$CONFIG"
        rustc --version
        cargo --version
        find core -path core/target -prune -o -type f \( -name '*.rs' -o -name Cargo.toml -o -name Cargo.lock -o -name uniffi.toml \) -print | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done
        shasum -a 256 Scripts/build-core.sh Scripts/toolchain.sh Scripts/harden-bindings.py
    } | shasum -a 256 | cut -d ' ' -f1
)"
if [ -f "$OUT/fingerprint" ] && [ "$(cat "$OUT/fingerprint")" = "$FINGERPRINT" ] \
    && [ -f "$OUT/MDemoCoreFFI.xcframework/Info.plist" ] \
    && [ -f "$OUT/MDemoCoreFFI.xcframework/macos-arm64_x86_64/libmdemo_ffi.a" ] \
    && [ -f "$OUT/MDemoCoreFFI.xcframework/macos-arm64_x86_64/Headers/module.modulemap" ] \
    && [ -f "$GENERATED/MDemoBindings.swift" ]; then
    echo "✓ Rust 핵심 변경 없음 ($CONFIG)"
    exit 0
fi
FLAGS=(--profile dev)
PROFILE=debug
if [ "$CONFIG" = release ]; then FLAGS=(--profile release); PROFILE=release; fi
cd "$ROOT/core"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --locked -p mdemo-ffi --target "$target" "${FLAGS[@]}"
done
STAGE="$(mktemp -d "$OUT/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/headers" "$STAGE/generated"
lipo -create "target/aarch64-apple-darwin/$PROFILE/libmdemo_ffi.a" \
    "target/x86_64-apple-darwin/$PROFILE/libmdemo_ffi.a" -output "$STAGE/libmdemo_ffi.a"
# 실행 중인 맥과 같은 아키텍처의 동적 라이브러리에서 메타데이터만 읽는다.
case "$(uname -m)" in arm64) HOST=aarch64-apple-darwin ;; *) HOST=x86_64-apple-darwin ;; esac
cargo run --locked -p uniffi-bindgen -- generate \
    --library "target/$HOST/$PROFILE/libmdemo_ffi.dylib" \
    --config crates/mdemo-ffi/uniffi.toml --language swift --out-dir "$STAGE/generated" --no-format
python3 "$ROOT/Scripts/harden-bindings.py" "$STAGE/generated/MDemoBindings.swift"
cp "$STAGE/generated/"*.h "$STAGE/headers/"
cp "$STAGE/generated/"*.modulemap "$STAGE/headers/module.modulemap"
xcodebuild -create-xcframework -library "$STAGE/libmdemo_ffi.a" \
    -headers "$STAGE/headers" -output "$STAGE/MDemoCoreFFI.xcframework"
rm -rf "$OUT/MDemoCoreFFI.xcframework"
mv "$STAGE/MDemoCoreFFI.xcframework" "$OUT/"
mkdir -p "$GENERATED"
cp "$STAGE/generated/"*.swift "$GENERATED/"
echo "$FINGERPRINT" > "$OUT/fingerprint"
echo "✓ Rust 핵심 · Swift 바인딩 생성 완료 ($CONFIG)"
