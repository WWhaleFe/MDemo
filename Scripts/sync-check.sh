#!/bin/bash
# 두 기기와 메모리 드라이브의 Swift/Rust 교차 시나리오.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
cargo build --offline --locked --manifest-path "$ROOT/core/Cargo.toml" -p mdemo-golden --bin mdemo-golden
SWIFT_CLI="$("$ROOT/Scripts/golden-build-swift.sh")"
export MDEMO_GOLDEN_SWIFT="$SWIFT_CLI"
python3 "$ROOT/Scripts/sync-check.py" "${1:-quick}"
