#!/bin/bash
# 본문을 읽지 않고 그림자 기록의 집계와 차이 경로만 표시한다.
set -euo pipefail
python3 - "${1:-$HOME/Library/Application Support/MDemo/Shadow}" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
try:
    summary = json.loads((root / 'shadow-summary.json').read_text())
    rows = [json.loads(line) for line in (root / 'shadow-log.jsonl').read_text().splitlines() if line]
except (OSError, ValueError):
    print('그림자 기록을 읽을 수 없습니다.', file=sys.stderr)
    sys.exit(2)
print('그림자 실행 요약')
print('시작:', summary['started'], '마지막:', summary['last'])
for op, counts in sorted(summary['operations'].items()):
    print(f"{op}: 같음 {counts.get('same', 0)}, 차이 {counts.get('diff', 0)}, 생략 {counts.get('skipped', 0)}, 오류 {counts.get('error', 0)}")
diffs = [row for row in rows if row.get('result') == 'diff']
print('차이 목록:', len(diffs), '건')
for row in diffs:
    print(row['op'], row.get('id', ''), ', '.join(row.get('paths', [])))
sys.exit(1 if diffs else 0)
PY
