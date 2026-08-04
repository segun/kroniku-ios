#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/run-ios.sh <device-id>

Builds, installs, and launches the Kroniku iOS app on the specified destination.
- For simulator IDs, this script uses simctl.
- For physical device IDs, this script uses devicectl when available.

Use ./scripts/list-ios-devices.sh to discover valid device IDs.

Environment overrides:
  SCHEME=Kroniku
  CONFIGURATION=Debug
  BUNDLE_ID=com.kroniku.app
  DERIVED_DATA=<path>
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

DEVICE_ID="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$IOS_DIR/Kroniku.xcodeproj"
SCHEME="${SCHEME:-Kroniku}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.kroniku.app}"
DERIVED_DATA="${DERIVED_DATA:-$IOS_DIR/.derivedData}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Error: xcodebuild is not available." >&2
  exit 1
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Error: Xcode project not found at $PROJECT_PATH" >&2
  exit 1
fi

IS_SIMULATOR=false
if xcrun simctl list devices available | grep -Fq "($DEVICE_ID)"; then
  IS_SIMULATOR=true
fi

if [[ "$IS_SIMULATOR" == "true" ]]; then
  DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
  PRODUCT_DIR="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator"
else
  DESTINATION="id=$DEVICE_ID"
  PRODUCT_DIR="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"
fi

echo "Building scheme '$SCHEME' for destination '$DESTINATION'..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$(find "$PRODUCT_DIR" -maxdepth 1 -name "*.app" | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  echo "Error: Built app not found in $PRODUCT_DIR" >&2
  exit 1
fi

if [[ "$IS_SIMULATOR" == "true" ]]; then
  echo "Installing and launching on simulator $DEVICE_ID..."
  xcrun simctl bootstatus "$DEVICE_ID" -b || xcrun simctl boot "$DEVICE_ID"
  xcrun simctl install "$DEVICE_ID" "$APP_PATH"
  xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
  echo "App launched on simulator."
  exit 0
fi

if xcrun devicectl help >/dev/null 2>&1; then
  echo "Installing and launching on physical device $DEVICE_ID..."
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
  echo "App launched on physical device."
  exit 0
fi

echo "Build completed for physical device, but devicectl is unavailable to install/launch automatically."
echo "Built app: $APP_PATH"
