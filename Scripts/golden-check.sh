#!/bin/bash
# 구현별 출력을 임시 폴더에 만들고 기준 파일과 바이트 단위로 비교한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 1 ]; then
    echo "사용법: $0 swift|rust" >&2
    exit 2
fi
RUST_PENDING=()
case "$1" in
    swift) CLI="$ROOT/Scripts/golden-run-swift.sh" ;;
    rust)
        source "$ROOT/Scripts/toolchain.sh"
        cargo build --offline --locked --manifest-path "$ROOT/core/Cargo.toml" -p mdemo-golden --bin mdemo-golden
        CLI="$ROOT/core/target/debug/mdemo-golden" ;;
    *) echo "알 수 없는 구현: $1" >&2; exit 2 ;;
esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-golden-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$CFFIXED_USER_HOME"
"$CLI" "$ROOT/golden/inputs" "$WORK/output"
python3 - "$ROOT/golden/expected" "$WORK/output" "$1" ${RUST_PENDING[@]+"${RUST_PENDING[@]}"} <<'PY'
import pathlib, sys, itertools
expected, actual = map(pathlib.Path, sys.argv[1:3])
implementation = sys.argv[3]
pending = set(sys.argv[4:]) if implementation == "rust" else set()
names = lambda root: {p.relative_to(root) for p in root.rglob('*') if p.is_file()}
a, b = names(expected), names(actual)
failed = not a
if not a:
    print('실패: 기준 파일이 없습니다. make golden으로 생성하세요.')
for name in sorted(a | b):
    if str(name) in pending and name not in b:
        print(f"미이전: {name}")
        continue
    if name not in a or name not in b:
        print(f'차이: {name} ({"기준에 없음" if name not in a else "출력에 없음"})')
        failed = True
        continue
    left, right = (expected / name).read_bytes(), (actual / name).read_bytes()
    if left == right:
        continue
    failed = True
    print(f'차이: {name}')
    for line, (x, y) in enumerate(itertools.zip_longest(left.splitlines(keepends=True), right.splitlines(keepends=True)), 1):
        if x != y:
            print(f'  첫 차이 {line}행\n  기준: {x!r}\n  출력: {y!r}')
            break
if not failed:
    print(f'✓ {implementation} 골든 {len(a - {pathlib.Path(n) for n in pending})}개 바이트 일치')
sys.exit(1 if failed else 0)
PY
