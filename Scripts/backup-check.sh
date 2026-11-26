#!/bin/bash
# Swift ditto와 Rust ZIP의 트리 및 상호 가져오기 검사.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
cargo build --offline --locked --manifest-path "$ROOT/core/Cargo.toml" -p mdemo-golden --bin mdemo-golden
SWIFT_CLI="$("$ROOT/Scripts/golden-build-swift.sh")"
export MDEMO_GOLDEN_SWIFT="$SWIFT_CLI"
python3 "$ROOT/Scripts/backup-check.py"
