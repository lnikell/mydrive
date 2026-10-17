#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
python3 tools/check-publication.py
python3 tools/fetch-sparkle.py >/dev/null
python3 -m unittest discover -s tools -p 'test_*.py'
bash tools/test-core.sh
bash tools/test-mac-adapters.sh
bash tools/test-provider-adapters.sh
bash tools/test-updater.sh
cd "$TASK_ROOT/Transport"
export CARGO_HOME="$TASK_ROOT/Transport/.cargo-home"
cargo test --release --locked
cargo clippy --release --locked -- -D warnings
