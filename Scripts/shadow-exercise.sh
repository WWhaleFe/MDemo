#!/bin/bash
# 빠른 그림자 검사 (P7). 실제 데이터 폴더를 임시 폴더로 복제한 뒤 그 복제본에서만
# MemoStore 연산을 무작위로 돌리고 Swift · Rust 결과를 비교한다. 실제 폴더는 읽기만 한다.
# 사용법: Scripts/shadow-exercise.sh [시드 수=10] [시드당 연산 수=3000] [원본 데이터 폴더]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEEDS="${1:-10}"
STEPS="${2:-3000}"
SOURCE="${3:-$HOME/Library/Application Support/MDemo/Data}"
BIN="$("$ROOT/Scripts/golden-build-swift.sh" 2>/dev/null | tail -1)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-shadow-exercise.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for seed in $(seq 1 "$SEEDS"); do
    ditto "$SOURCE" "$WORK/data-$seed"
    "$BIN" shadow-exercise "$WORK/data-$seed" "$WORK/shadow-$seed" "$STEPS" "$seed"
    rm -rf "$WORK/data-$seed"
done
python3 - "$WORK" <<'PY'
import collections, glob, json, sys
total = collections.Counter(); skipped = collections.Counter()
for path in glob.glob(sys.argv[1] + '/shadow-*/shadow-log.jsonl'):
    for line in open(path):
        row = json.loads(line); total[(row['op'], row['result'])] += 1
        if row['result'] == 'skipped': skipped[row.get('skipped')] += 1
names = {'same': '같음', 'diff': '차이', 'skipped': '생략', 'error': '오류'}
for op in sorted({op for op, _ in total}):
    print(op + ': ' + ', '.join(f"{names[k]} {total[(op, k)]}" for k in names))
diff = sum(v for (_, k), v in total.items() if k == 'diff'); error = sum(v for (_, k), v in total.items() if k == 'error')
print(f"합계 {sum(total.values())}건, 차이 {diff}, 오류 {error}, 생략 이유 {dict(skipped)}")
sys.exit(1 if diff or error else 0)
PY
