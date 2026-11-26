#!/bin/bash
# Windows에서도 공통 핵심과 FFI가 빌드되는지 확인한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.sh"
cd "$ROOT/core"
cargo xwin build --locked --target x86_64-pc-windows-msvc -p mdemo-core -p mdemo-ffi --release
