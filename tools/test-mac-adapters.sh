#!/bin/bash
set -euo pipefail

# No GUI, Keychain lookup or NAS access. Use optimized Swift: callback actor
# inheritance failures can appear only when the callback actually executes.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/.build/mac-adapter-tests"
TASK_SDK="$(xcrun --show-sdk-path)"
TASK_ARCH="$(uname -m)"
mkdir -p "$TASK_BUILD/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$TASK_BUILD/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_BUILD/ModuleCache"
TASK_SWIFT=(xcrun swiftc -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macosx15.0"
            -swift-version 6 -O -parse-as-library -module-cache-path "$TASK_BUILD/ModuleCache")

run_test() {
  python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys

test = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    sys.exit(test.wait(timeout=30))
except subprocess.TimeoutExpired:
    # The helper tests deliberately launch uncooperative children. Terminate
    # the entire owned process group if a lifecycle regression hangs the suite.
    print("Adapter test exceeded its 30-second deadline.", file=sys.stderr)
    sys.exit(124)
finally:
    # Also clean descendants if a failed assertion exits before its helper does.
    try:
        os.killpg(test.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    test.wait()
PY
}

"${TASK_SWIFT[@]}" -module-name HelperOperationTests \
  "$TASK_ROOT/MacApp/Shared/HelperOperation.swift" \
  "$TASK_ROOT/MacApp/Tests/HelperOperationTests.swift" \
  -o "$TASK_BUILD/helper-operation-tests"
run_test "$TASK_BUILD/helper-operation-tests"

"${TASK_SWIFT[@]}" -module-name ConnectionMonitorTests \
  "$TASK_ROOT/MacApp/Host/ConnectionMonitor.swift" \
  "$TASK_ROOT/MacApp/Tests/ConnectionMonitorTests.swift" \
  -framework FileProvider -o "$TASK_BUILD/connection-monitor-tests"
run_test "$TASK_BUILD/connection-monitor-tests"

# Build the current Core sources into this test directory so a simultaneous
# app build cannot substitute a stale module or mutate our linked archive.
"${TASK_SWIFT[@]}" -whole-module-optimization -emit-library -static -emit-module \
  -module-name MyDriveCore -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/Core/Sources/MyDriveCore/*.swift \
  -emit-module-path "$TASK_BUILD/MyDriveCore.swiftmodule" -o "$TASK_BUILD/libMyDriveCore.a"

"${TASK_SWIFT[@]}" -module-name ConnectionStoreTests \
  -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT/MacApp/Shared/AppStorage.swift" "$TASK_ROOT/MacApp/Shared/ConnectionStore.swift" \
  "$TASK_ROOT/MacApp/Tests/ConnectionStoreTests.swift" "$TASK_BUILD/libMyDriveCore.a" \
  -lsqlite3 -o "$TASK_BUILD/connection-store-tests"
run_test "$TASK_BUILD/connection-store-tests"

"${TASK_SWIFT[@]}" -module-name ConnectionRemovalStorageTests \
  -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT/MacApp/Shared/DomainOwnerLease.swift" "$TASK_ROOT/MacApp/Shared/ConnectionRemovalStorage.swift" \
  "$TASK_ROOT/MacApp/Tests/ConnectionRemovalStorageTests.swift" "$TASK_BUILD/libMyDriveCore.a" \
  -lsqlite3 -o "$TASK_BUILD/connection-removal-storage-tests"
run_test "$TASK_BUILD/connection-removal-storage-tests"

for TASK_MODE in production development; do
  TASK_MODEL_SWIFT=("${TASK_SWIFT[@]}")
  if [[ "$TASK_MODE" == development ]]; then TASK_MODEL_SWIFT+=(-D MYDRIVE_DEVELOPMENT); fi
  "${TASK_MODEL_SWIFT[@]}" -module-name DriveModelTests \
    -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
    "$TASK_ROOT"/MacApp/Shared/*.swift \
    "$TASK_ROOT/MacApp/Host/ConnectionMonitor.swift" "$TASK_ROOT/MacApp/Host/DomainManagement.swift" \
    "$TASK_ROOT/MacApp/Host/DriveConnectionBackend.swift" "$TASK_ROOT/MacApp/Host/DriveModel.swift" \
    "$TASK_ROOT/MacApp/Host/AppModel.swift" "$TASK_ROOT/MacApp/Tests/DriveModelTests.swift" \
    "$TASK_BUILD/libMyDriveCore.a" -lsqlite3 -framework FileProvider -framework Security -framework AppKit \
    -o "$TASK_BUILD/drive-model-tests-$TASK_MODE"
  run_test "$TASK_BUILD/drive-model-tests-$TASK_MODE"
done

"${TASK_SWIFT[@]}" -D MYDRIVE_DEVELOPMENT -module-name TransportRequestTests \
  -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/MacApp/Shared/*.swift "$TASK_ROOT/MacApp/Tests/TransportRequestTests.swift" \
  "$TASK_BUILD/libMyDriveCore.a" -lsqlite3 -framework FileProvider -framework Security \
  -o "$TASK_BUILD/transport-request-tests"
run_test "$TASK_BUILD/transport-request-tests" "$TASK_ROOT/MacApp/Tests/Fixtures/transport_request_probe.py"

"${TASK_SWIFT[@]}" -module-name DomainLifetimeTests \
  -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/MacApp/Shared/*.swift "$TASK_ROOT/MacApp/Host/DomainManagement.swift" \
  "$TASK_ROOT/MacApp/Tests/DomainLifetimeTests.swift" "$TASK_BUILD/libMyDriveCore.a" \
  -lsqlite3 -framework FileProvider -framework Security -framework AppKit \
  -o "$TASK_BUILD/domain-lifetime-tests"
run_test "$TASK_BUILD/domain-lifetime-tests"

# Exercise the actual diagnostic owner/report with a loopback-only connection.
# Development-only code must also compile against the real host dependencies.
"${TASK_SWIFT[@]}" -D MYDRIVE_DEVELOPMENT -module-name LocalNetworkProbeTests \
  -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/MacApp/Shared/*.swift \
  "$TASK_ROOT/MacApp/Host/DomainManagement.swift" \
  "$TASK_ROOT/MacApp/Host/HostDiagnostic.swift" \
  "$TASK_ROOT/MacApp/Host/ProbeReport.swift" \
  "$TASK_ROOT/MacApp/Host/LocalNetworkProbe.swift" \
  "$TASK_ROOT/MacApp/Tests/LocalNetworkProbeTests.swift" "$TASK_BUILD/libMyDriveCore.a" \
  -lsqlite3 -framework FileProvider -framework Security -framework AppKit -framework Network \
  -o "$TASK_BUILD/local-network-probe-tests"
run_test "$TASK_BUILD/local-network-probe-tests"
