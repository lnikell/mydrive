#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEST="$TASK_ROOT/.build/core-tests"
# Keep Testing's module and runtime with the selected compiler. Standalone
# Command Line Tools have no PlatformPath and use their own framework folder.
if TASK_PLATFORM="$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)"; then
  TASK_FRAMEWORKS="$TASK_PLATFORM/Developer/Library/Frameworks"
else
  TASK_FRAMEWORKS="$(xcode-select --print-path)/Library/Developer/Frameworks"
fi
if [[ ! -d "$TASK_FRAMEWORKS/Testing.framework" ]]; then
  echo "Testing.framework is missing from the selected developer tools: $TASK_FRAMEWORKS" >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$TASK_TEST/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_TEST/modules"
xcrun --sdk macosx swift test --package-path "$TASK_ROOT/Core" --disable-sandbox --disable-xctest \
  --scratch-path "$TASK_TEST/build" --cache-path "$TASK_TEST/cache" \
  --config-path "$TASK_TEST/config" --security-path "$TASK_TEST/security" \
  -Xswiftc -F -Xswiftc "$TASK_FRAMEWORKS" \
  -Xlinker -F -Xlinker "$TASK_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$TASK_FRAMEWORKS"
