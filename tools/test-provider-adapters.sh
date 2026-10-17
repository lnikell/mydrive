#!/bin/bash
set -euo pipefail

# Exercise the real extension adapters without a registered domain, credentials,
# Keychain lookups, or NAS access. Optimized Swift catches callback actor traps.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/mydrive-provider-adapters.XXXXXX")"
trap 'rm -rf "$TASK_BUILD"' EXIT
TASK_SDK="$(xcrun --show-sdk-path)"
TASK_ARCH="$(uname -m)"
mkdir -p "$TASK_BUILD/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$TASK_BUILD/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_BUILD/ModuleCache"
TASK_SWIFT=(xcrun swiftc -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macosx15.0"
            -swift-version 6 -O -parse-as-library -module-cache-path "$TASK_BUILD/ModuleCache")

# Keep both the module and archive isolated from concurrent app builds.
"${TASK_SWIFT[@]}" -whole-module-optimization -emit-library -static -emit-module \
  -module-name MyDriveCore -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/Core/Sources/MyDriveCore/*.swift \
  -emit-module-path "$TASK_BUILD/MyDriveCore.swiftmodule" -o "$TASK_BUILD/libMyDriveCore.a"

for TASK_MODE in production development; do
TASK_MODE_SWIFT=("${TASK_SWIFT[@]}")
if [ "$TASK_MODE" = development ]; then TASK_MODE_SWIFT+=(-D MYDRIVE_DEVELOPMENT); fi
"${TASK_MODE_SWIFT[@]}" -application-extension -module-name MyDriveProviderTests \
  -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/MacApp/Shared/*.swift "$TASK_ROOT"/MacApp/Extension/*.swift \
  "$TASK_ROOT"/MacApp/Extension/Tests/*.swift "$TASK_BUILD/libMyDriveCore.a" \
  -lsqlite3 -framework FileProvider -framework Security \
  -o "$TASK_BUILD/provider-adapter-tests-$TASK_MODE"

python3 - "$TASK_BUILD/provider-adapter-tests-$TASK_MODE" <<'PY'
import os
import signal
import subprocess
import sys

test = subprocess.Popen([sys.argv[1]], start_new_session=True)
try:
    sys.exit(test.wait(timeout=30))
except subprocess.TimeoutExpired:
    print("Provider adapter test exceeded its 30-second deadline.", file=sys.stderr)
    sys.exit(124)
finally:
    # The owner-lifetime test launches a child. Reap the whole owned process
    # group even when an assertion or lifecycle regression interrupts cleanup.
    try:
        os.killpg(test.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    test.wait()
PY
done
