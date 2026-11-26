#!/bin/bash
# 암호 메모 교차 검사 (P4).
#
# golden/lock-scenarios/*.json 을 Swift 구현과 Rust 구현으로 각각 빈 임시 폴더에서 실행한다.
# 연산에 "phase": N 이 있으면 단계별로 끊어 실행할 수 있어서, 한 구현이 만든 암호 메모(데이터 폴더와
# keychain.json)를 다른 구현이 이어 받아 열고 · 파기하고 · 실패 횟수를 이어 센다.
#   SS: 전부 Swift, RR: 전부 Rust, SR: 1단계 Swift 뒤로 Rust, RS: 1단계 Rust 뒤로 Swift,
#   3단계 이상이면 번갈아 실행(SRS.., RSR..)도 한다.
# 비교: 연산별 결과 기록(성공/오류 종류)과, 정규화한 최종 상태(폴더 트리, 파일 바이트, 휴지통 폴더 시각,
# 키체인 상태). 암호문 · 솔트 · 감싼 열쇠는 nonce가 무작위라 "크기"만 비교하고, 서로의 암호문을 열 수 있는지는
# 시나리오 안의 assert 연산(본문 · 첨부 평문 비교)이 확인한다.
# 키 유도가 최소 200만 번이라 오래 걸린다. 기본은 빠른 시나리오만, `full` 인자를 주면 golden/lock-scenarios/full 도 돈다.
# 실제 홈 · 데이터 폴더 · 키체인은 쓰지 않는다(메모리 대역 + keychain.json 가짜 파일, 임시 폴더).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
MODE="${1:-quick}"
case "$MODE" in quick|full) ;; *) echo "사용법: $0 [quick|full]" >&2; exit 2 ;; esac

cargo build --offline --locked --manifest-path "$ROOT/core/Cargo.toml" -p mdemo-golden --bin mdemo-golden
RUST_CLI="$ROOT/core/target/debug/mdemo-golden"

# Swift 쪽은 한 번만 빌드하고 실행 파일을 직접 부른다(시나리오를 병렬로 돌리기 위해).
BUILD_KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c 1-12)"
SCRATCH="${TMPDIR:-/tmp}/mdemo-swift-$BUILD_KEY"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --package-path "$ROOT/Packages/Golden" --scratch-path "$SCRATCH" -c debug 2>&1 | grep -E "error|Compiling|Build complete" | tail -3 || true
SWIFT_CLI="$(swift build --package-path "$ROOT/Packages/Golden" --scratch-path "$SCRATCH" -c debug --show-bin-path)/mdemo-golden"
[ -x "$SWIFT_CLI" ] || { echo "실패: Swift 실행 파일이 없습니다: $SWIFT_CLI"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdemo-lock-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$CFFIXED_USER_HOME"

SCENARIOS=("$ROOT"/golden/lock-scenarios/*.json)
if [ "$MODE" = full ]; then SCENARIOS+=("$ROOT"/golden/lock-scenarios/full/*.json); fi

# 한 시나리오의 모든 조합을 실행하고 비교한다. 결과는 $WORK/<이름>.result 에 남긴다.
run_one() {
    local scenario="$1" name; name="$(basename "$1" .json)"
    local dir="$WORK/$name"; mkdir -p "$dir"
    local phases; phases="$(python3 -c "import json,sys; print(max([o.get('phase',1) for o in json.load(open(sys.argv[1]))['ops']]))" "$scenario")"
    local combos="SS RR"
    if [ "$phases" -ge 2 ]; then combos="$combos SR RS"; fi
    if [ "$phases" -ge 3 ]; then combos="$combos SRS RSR"; fi
    local combo
    for combo in $combos; do
        mkdir -p "$dir/$combo"; : > "$dir/$combo.log"
        local p
        for p in $(seq 1 "$phases"); do
            local who
            case "$combo" in
                SS) who=S ;; RR) who=R ;;
                SR) if [ "$p" -eq 1 ]; then who=S; else who=R; fi ;;
                RS) if [ "$p" -eq 1 ]; then who=R; else who=S; fi ;;
                SRS) if [ $((p % 2)) -eq 1 ]; then who=S; else who=R; fi ;;
                RSR) if [ $((p % 2)) -eq 1 ]; then who=R; else who=S; fi ;;
            esac
            local cli="$RUST_CLI"; [ "$who" = S ] && cli="$SWIFT_CLI"
            if ! "$cli" lock "$scenario" "$dir/$combo" --phase "$p" >>"$dir/$combo.log" 2>"$dir/$combo.err"; then
                { echo "실패: $name [$combo] $p단계 ($who) 실행 오류"; tail -n 5 "$dir/$combo.log"; cat "$dir/$combo.err"; } > "$WORK/$name.result"
                return 1
            fi
        done
    done
    python3 - "$scenario" "$dir" "$phases $combos" >"$WORK/$name.result" <<'PY'
import base64, json, os, pathlib, re, subprocess, sys
scenario, work = sys.argv[1], pathlib.Path(sys.argv[2])
_, *combos = sys.argv[3].split()
combos = sys.argv[3].split()[1:]
name = work.name

def b64len(text):
    return len(base64.b64decode(text))

def xattr_excluded(path):
    r = subprocess.run(['xattr', '-p', 'com.apple.metadata:com_apple_backup_excludeItem', str(path)], capture_output=True)
    return r.returncode == 0

def normalize(root):
    state = {}
    for path in sorted(root.rglob('*')):
        rel = str(path.relative_to(root))
        parts = pathlib.PurePath(rel).parts
        if path.is_dir():
            entry = {'dir': True}
            if len(parts) == 2 and parts[0] == 'trash':
                entry['mtime_ms'] = round(path.stat().st_mtime * 1000)
            if len(parts) == 2 and parts[0] == 'memos':
                md = path / 'memo.md'
                entry['backupExcluded'] = xattr_excluded(path) if md.exists() and b'locked: true' in md.read_bytes() else None
            state[rel] = entry
            continue
        data = path.read_bytes()
        if rel == 'keychain.json':
            table = json.loads(data)
            state[rel] = {'keys': {k: f'<wrapped {b64len(v)} bytes>' for k, v in table.get('keys', {}).items()},
                          'failures': table.get('failures', {})}
        elif rel.endswith('.enc'):
            state[rel] = f'<enc {len(data)} bytes>'
        elif parts[-1] == 'memo.md' and b'locked: true' in data:
            text = data.decode('utf-8')
            head, sep, rest = text.partition('\n---\n')
            lines = []
            for line in head.split('\n'):
                if line.startswith('lockSalt: '):
                    line = f'lockSalt: <{b64len(line[len("lockSalt: "):])} bytes>'
                lines.append(line)
            state[rel] = '\n'.join(lines) + sep + f'<cipher {b64len(rest.strip())} bytes>'
        else:
            state[rel] = data.decode('utf-8', 'replace')
    return state

def log_lines(path):
    return [l for l in path.read_text().splitlines() if l and l[0].isdigit()]

problems = []
base = combos[0]
base_state, base_log = normalize(work / base), log_lines(work / f'{base}.log')
for combo in combos[1:]:
    state, log = normalize(work / combo), log_lines(work / f'{combo}.log')
    if log != base_log:
        problems.append(f'차이: [{base}] 와 [{combo}] 의 연산 결과 기록이 다름')
        for a, b in zip(base_log, log):
            if a != b:
                problems.append(f'  {base}: {a}\n  {combo}: {b}'); break
        if len(base_log) != len(log):
            problems.append(f'  줄 수 {len(base_log)} / {len(log)}')
    for rel in sorted(set(base_state) | set(state)):
        a, b = base_state.get(rel, '<없음>'), state.get(rel, '<없음>')
        if a != b:
            problems.append(f'차이: [{base}] 와 [{combo}] 의 {rel}\n  {base}: {str(a)[:300]!r}\n  {combo}: {str(b)[:300]!r}')
if problems:
    print(f'실패: {name}')
    print('\n'.join(problems))
    sys.exit(1)
files = sum(1 for v in base_state.values() if not (isinstance(v, dict) and v.get('dir')))
print(f'✓ {name}: 조합 {len(combos)}개({" ".join(combos)}) 결과 기록 {len(base_log)}줄 · 파일 {files}개 일치')
PY
}

PIDS=(); NAMES=()
for scenario in "${SCENARIOS[@]}"; do
    run_one "$scenario" &
    PIDS+=($!); NAMES+=("$(basename "$scenario" .json)")
done
FAILED=0
for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then FAILED=1; fi
    cat "$WORK/${NAMES[$i]}.result"
done
if [ "${#SCENARIOS[@]}" -eq 0 ]; then echo "실패: golden/lock-scenarios 에 시나리오가 없습니다."; exit 1; fi
if [ "$FAILED" -ne 0 ]; then echo "✗ 암호 교차 검사 실패"; exit 1; fi
echo "✓ 암호 교차 시나리오 ${#SCENARIOS[@]}개 Swift/Rust 일치 ($MODE)"
