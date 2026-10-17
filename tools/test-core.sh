#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEST="$TASK_ROOT/.build/core-tests"
TASK_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
export CLANG_MODULE_CACHE_PATH="$TASK_TEST/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_TEST/modules"
swift test --package-path "$TASK_ROOT/Core" --disable-sandbox --disable-xctest \
  --scratch-path "$TASK_TEST/build" --cache-path "$TASK_TEST/cache" \
  --config-path "$TASK_TEST/config" --security-path "$TASK_TEST/security" \
  -Xswiftc -F -Xswiftc "$TASK_FRAMEWORKS" \
  -Xlinker -F -Xlinker "$TASK_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$TASK_FRAMEWORKS"
