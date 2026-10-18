#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="${MYDRIVE_BUILD_DIR:-$TASK_ROOT/.build/macos}"
TASK_DIST="${MYDRIVE_DIST_DIR:-$TASK_ROOT/dist}"
TASK_SDK="$(xcrun --show-sdk-path)"
TASK_ARCH="${MYDRIVE_ARCH:-$(uname -m)}"
TASK_SIGNING="${MYDRIVE_SIGN_IDENTITY:--}"
if [[ "${MYDRIVE_RELEASE:-0}" == 1 && "$TASK_SIGNING" == "-" ]]; then
  echo "A release build requires MYDRIVE_SIGN_IDENTITY; ad-hoc signing is development only." >&2
  exit 1
fi
if [[ "$TASK_ARCH" != "$(uname -m)" ]]; then
  echo "Cross-architecture builds are not implemented; build on the requested architecture." >&2
  exit 1
fi
if [[ "$TASK_SIGNING" != "-" && "$TASK_ARCH" != arm64 ]]; then
  echo "The initial production release supports arm64 only." >&2
  exit 1
fi
mkdir -p "$TASK_BUILD" "$TASK_DIST"
TASK_BUILD="$(cd "$TASK_BUILD" && pwd)"
TASK_DIST="$(cd "$TASK_DIST" && pwd)"
TASK_SPARKLE="$(python3 "$TASK_ROOT/tools/fetch-sparkle.py")"
TASK_STAGE="$(mktemp -d "$TASK_BUILD/stage.XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
TASK_APP="$TASK_STAGE/MyDrive.app"
TASK_EXTENSION="$TASK_APP/Contents/PlugIns/MyDriveProvider.appex"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Helpers" \
  "$TASK_EXTENSION/Contents/MacOS" "$TASK_EXTENSION/Contents/Helpers"
# Validate release configuration and both profiles before compiling anything.
python3 "$TASK_ROOT/tools/macos_build.py" prepare --app "$TASK_APP" --build "$TASK_BUILD" \
  --sparkle "$TASK_SPARKLE" --identity "$TASK_SIGNING"
TASK_APP_SWIFT_FLAGS=(-parse-as-library)
if [[ "$TASK_SIGNING" == "-" ]]; then TASK_APP_SWIFT_FLAGS+=(-D MYDRIVE_DEVELOPMENT); fi
export CLANG_MODULE_CACHE_PATH="$TASK_BUILD/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_BUILD/ModuleCache"
(cd "$TASK_ROOT/Transport" && CARGO_HOME="$TASK_ROOT/Transport/.cargo-home" cargo build --release --locked)
if [[ "$(lipo -archs "$TASK_ROOT/Transport/target/release/nas-transport")" != "$TASK_ARCH" ]]; then
  echo "The NAS helper architecture does not match the requested app architecture." >&2
  exit 1
fi
# Retain complete upstream licenses before either bundle is signed. The app's
# MIT license does not relicense Cargo dependencies or the Sparkle framework.
python3 "$TASK_ROOT/tools/third_party_notices.py" --app "$TASK_APP" --sparkle "$TASK_SPARKLE"
cp "$TASK_ROOT/MacApp/Resources/MyDrive.icns" "$TASK_APP/Contents/Resources/MyDrive.icns"
cp "$TASK_ROOT/MacApp/Resources/MyDrive.icns" "$TASK_EXTENSION/Contents/Resources/MyDrive.icns"
# The host UI draws the design's stroke icons from these SVG files.
cp -R "$TASK_ROOT/MacApp/Resources/Icons" "$TASK_APP/Contents/Resources/Icons"
xcrun swiftc -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macosx15.0" -swift-version 6 -O \
  -parse-as-library -whole-module-optimization -emit-library -static -emit-module \
  -module-name MyDriveCore -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/Core/Sources/MyDriveCore/*.swift \
  -emit-module-path "$TASK_BUILD/MyDriveCore.swiftmodule" -o "$TASK_BUILD/libMyDriveCore.a"
xcrun swiftc -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macosx15.0" -swift-version 6 -O \
  "${TASK_APP_SWIFT_FLAGS[@]}" -application-extension -module-name MyDriveProvider \
  -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  "$TASK_ROOT"/MacApp/Shared/*.swift "$TASK_ROOT"/MacApp/Extension/*.swift \
  "$TASK_BUILD/libMyDriveCore.a" -lsqlite3 -framework FileProvider -framework Security \
  -Xlinker -e -Xlinker _NSExtensionMain -o "$TASK_EXTENSION/Contents/MacOS/MyDriveProvider"
xcrun swiftc -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macosx15.0" -swift-version 6 -O \
  "${TASK_APP_SWIFT_FLAGS[@]}" -module-name MyDrive -I "$TASK_BUILD" -I "$TASK_ROOT/Core/Sources/CSQLite" \
  -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$TASK_ROOT"/MacApp/Shared/*.swift "$TASK_ROOT"/MacApp/Host/*.swift \
  "$TASK_BUILD/libMyDriveCore.a" -lsqlite3 -framework FileProvider -framework Security -framework SwiftUI \
  -o "$TASK_APP/Contents/MacOS/MyDrive"
cp "$TASK_ROOT/Transport/target/release/nas-transport" "$TASK_APP/Contents/Helpers/nas-transport"
cp "$TASK_ROOT/Transport/target/release/nas-transport" "$TASK_EXTENSION/Contents/Helpers/nas-transport"
python3 "$TASK_ROOT/tools/macos_build.py" sign --app "$TASK_APP" --build "$TASK_BUILD" --identity "$TASK_SIGNING"
# Replace complete bundles; never truncate executable files in a running bundle.
python3 "$TASK_ROOT/tools/macos_build.py" publish --app "$TASK_APP" --destination "$TASK_DIST/MyDrive.app"
echo "Built $TASK_DIST/MyDrive.app"
