#!/bin/bash
# 메모를 묶어 Swift와 Rust가 같은 입력을 바이트까지 동일하게 처리하는지 검사한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
N="${1:-2000}"
SEED="${2:-20261126}"
if ! [[ "$N" =~ ^[0-9]+$ && "$SEED" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ]; then
    echo "사용법: $0 [양의 건수=2000] [정수 시드]" >&2
    exit 2
fi
cargo build --offline --locked --manifest-path "$ROOT/core/Cargo.toml" -p mdemo-golden --bins
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-fuzz.XXXXXX")"
mkdir -p "$WORK/run"; : > "$WORK/search-diff-count"
trap 'rm -rf "$WORK"' EXIT
START=$SECONDS
DONE=0
while [ "$DONE" -lt "$N" ]; do
    COUNT=$((N - DONE))
    if [ "$COUNT" -gt 500 ]; then COUNT=500; fi
    BATCH_SEED=$((SEED + DONE))
    rm -rf "$WORK/input" "$WORK/swift" "$WORK/rust"
    cp -R "$ROOT/golden/inputs" "$WORK/input"
    rm -rf "$WORK/input/memos"
    "$ROOT/core/target/debug/mdemo-fuzzgen" "$WORK/input" "$COUNT" "$BATCH_SEED"
    STATUS=0
    "$ROOT/Scripts/golden-run-swift.sh" "$WORK/input" "$WORK/swift" >"$WORK/swift.log" 2>&1 || STATUS=1
    "$ROOT/core/target/debug/mdemo-golden" "$WORK/input" "$WORK/rust" >"$WORK/rust.log" 2>&1 || STATUS=1
    if [ "$STATUS" -eq 0 ]; then
        python3 - "$WORK/swift" "$WORK/rust" <<'PY' || STATUS=1
import pathlib, sys
swift, rust = map(pathlib.Path, sys.argv[1:])
names = {'board.json', 'groups.json', 'device-state.json', 'destroyed.json', 'local-only.json', 'board-calculations.json', 'relations.json', 'search-results.json', 'markdown-results.json'}
names |= {str(p.relative_to(swift)) for p in (swift / 'memos').glob('*.md')}
names |= {str(p.relative_to(rust)) for p in (rust / 'memos').glob('*.md')}
differences = [n for n in sorted(names) if not (swift/n).is_file() or not (rust/n).is_file() or (swift/n).read_bytes() != (rust/n).read_bytes()]
# 검색 판정은 맥에서 Foundation(Swift)에 남긴다(계획표 1장). Rust 검색은 Windows 기본 구현이라
# 무작위 비교의 검색 차이는 실패로 치지 않고 건수만 남긴다. 고정 사례 477개 일치는 golden-check가 강제한다.
if 'search-results.json' in differences:
    import json
    a = json.loads((swift/'search-results.json').read_text()); b = json.loads((rust/'search-results.json').read_text())
    n = sum(1 for x, y in zip(a, b) if x != y)
    with open(pathlib.Path(sys.argv[1]).parent / 'search-diff-count', 'a') as f: f.write(f'{n}\n')
    differences.remove('search-results.json')
for name in differences:
    print(f'차이: {name}')
print(f'차이 파일 {len(differences)}개') if differences else None
sys.exit(bool(differences))
PY
    fi
    if [ "$STATUS" -ne 0 ]; then
        FAILURE="$ROOT/golden/fuzz-failures/seed-$BATCH_SEED-$(date +%s)"
        mkdir -p "$FAILURE"
        cp -R "$WORK/input" "$WORK/swift.log" "$WORK/rust.log" "$FAILURE/"
        for impl in swift rust; do
            if [ -d "$WORK/$impl" ]; then cp -R "$WORK/$impl" "$FAILURE/"; fi
        done
        tail -n 12 "$WORK/swift.log" "$WORK/rust.log"
        echo "실패: 입력과 출력 보존 $FAILURE"
        echo "퍼즈: 완료 $DONE, 실패 묶음 $COUNT, 경과 $((SECONDS - START))초, 시드 $SEED"
        exit 1
    fi
    DONE=$((DONE + COUNT))
    if [ $((DONE % 5000)) -eq 0 ] || [ "$DONE" -eq "$N" ]; then
        echo "퍼즈: $DONE/$N, $((SECONDS - START))초, 차이 0건, 시드 $SEED (참고: 검색 판정 차이 $(awk '{s+=$1} END {print s+0}' "$WORK/search-diff-count")건, 맥은 Swift 검색 유지)"
    fi
done
