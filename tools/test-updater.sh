#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SPARKLE="$(python3 "$TASK_ROOT/tools/fetch-sparkle.py")"
TASK_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/mydrive-updater-tests.XXXXXX")"
trap 'rm -rf "$TASK_BUILD"' EXIT
mkdir -p "$TASK_BUILD/ModuleCache"
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx15.0" \
  -swift-version 6 -O -parse-as-library -module-cache-path "$TASK_BUILD/ModuleCache" \
  -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE" \
  "$TASK_ROOT/MacApp/Host/UpdateController.swift" "$TASK_ROOT/MacApp/Tests/UpdateControllerTests.swift" \
  -o "$TASK_BUILD/updater-tests"
"$TASK_BUILD/updater-tests"
