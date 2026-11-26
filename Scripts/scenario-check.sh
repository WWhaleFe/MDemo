#!/bin/bash
# 데이터 폴더 시나리오 비교 (P3).
#
# golden/scenarios/*.json 의 연산 목록을 Swift 구현과 Rust 구현으로 각각 빈 임시 폴더에서 실행하고,
# 폴더 트리, 파일 바이트, 휴지통 폴더와 시나리오가 지정한 파일(mtimeCheck)의 수정 시각을 비교한다.
# 차이는 파일별로 보여 주고 실패한다. 실제 홈 · 데이터 폴더 · 키체인은 쓰지 않는다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
cargo build --offline --locked --manifest-path "$ROOT/core/Cargo.toml" -p mdemo-golden --bin mdemo-golden
RUST_CLI="$ROOT/core/target/debug/mdemo-golden"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-scenario-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$CFFIXED_USER_HOME"

FAILED=0
COUNT=0
for scenario in "$ROOT"/golden/scenarios/*.json; do
    name="$(basename "$scenario" .json)"
    COUNT=$((COUNT + 1))
    mkdir -p "$WORK/$name/swift" "$WORK/$name/rust"
    if ! "$ROOT/Scripts/golden-run-swift.sh" scenario "$scenario" "$WORK/$name/swift" >"$WORK/$name/swift.log" 2>&1; then
        echo "실패: $name (Swift 실행 오류)"; tail -n 5 "$WORK/$name/swift.log"; FAILED=1; continue
    fi
    if ! "$RUST_CLI" scenario "$scenario" "$WORK/$name/rust" >"$WORK/$name/rust.log" 2>&1; then
        echo "실패: $name (Rust 실행 오류)"; cat "$WORK/$name/rust.log"; FAILED=1; continue
    fi
    if python3 - "$scenario" "$WORK/$name/swift" "$WORK/$name/rust" "$name" <<'PY'
import json, os, pathlib, sys
scenario, swift, rust, name = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]
checked = set(json.load(open(scenario)).get("mtimeCheck", []))

def walk(root):
    entries = {}
    for path in sorted(root.rglob('*')):
        entries[str(path.relative_to(root))] = path
    return entries

a, b = walk(swift), walk(rust)
problems = []
files = 0
for rel in sorted(set(a) | set(b)):
    if rel not in a or rel not in b:
        problems.append(f'차이: {rel} ({"Rust에 없음" if rel not in b else "Swift에 없음"})')
        continue
    left, right = a[rel], b[rel]
    if left.is_dir() != right.is_dir():
        problems.append(f'차이: {rel} (폴더/파일 종류가 다름)')
        continue
    if left.is_file():
        files += 1
        x, y = left.read_bytes(), right.read_bytes()
        if x != y:
            problems.append(f'차이: {rel} (바이트)\n  Swift: {x[:400]!r}\n  Rust:  {y[:400]!r}')
    # 휴지통 항목 폴더와 지정한 파일은 수정 시각도 같아야 한다(밀리초 단위).
    parts = pathlib.PurePath(rel).parts
    if (len(parts) == 2 and parts[0] == 'trash') or rel in checked:
        mx, my = round(left.stat().st_mtime * 1000), round(right.stat().st_mtime * 1000)
        if mx != my:
            problems.append(f'차이: {rel} (수정 시각)\n  Swift: {mx} ms\n  Rust:  {my} ms')
for rel in sorted(checked):
    if rel not in a:
        problems.append(f'차이: mtimeCheck 대상이 없음: {rel}')
if problems:
    print(f'실패: {name}')
    print('\n'.join(problems))
    sys.exit(1)
print(f'✓ {name}: 파일 {files}개 바이트 일치, 수정 시각 비교 {sum(1 for r in a if (len(pathlib.PurePath(r).parts) == 2 and pathlib.PurePath(r).parts[0] == "trash") or r in checked)}곳 일치')
PY
    then :; else FAILED=1; fi
done

if [ "$COUNT" -eq 0 ]; then
    echo "실패: golden/scenarios 에 시나리오가 없습니다."; exit 1
fi
if [ "$FAILED" -ne 0 ]; then
    echo "✗ 시나리오 비교 실패"; exit 1
fi
echo "✓ 시나리오 ${COUNT}개 Swift/Rust 일치"
