#!/bin/bash
# 성공한 전체 출력만 기준 폴더로 교체해 오래된 파일도 함께 정리한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-golden.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$CFFIXED_USER_HOME"
"$ROOT/Scripts/golden-run-swift.sh" "$ROOT/golden/inputs" "$WORK/output"
mkdir -p "$ROOT/golden/expected"
find "$ROOT/golden/expected" -type f -delete
cp -R "$WORK/output/." "$ROOT/golden/expected/"
echo "✓ Swift 골든 생성 완료"
