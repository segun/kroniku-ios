#!/usr/bin/env bash
set -euo pipefail

echo "== Available iOS Simulators =="
xcrun simctl list devices available

echo
echo "== Connected Physical Devices (devicectl) =="
if xcrun devicectl help >/dev/null 2>&1; then
  # Shows connected devices and their identifiers.
  xcrun devicectl list devices
else
  echo "devicectl is not available on this Xcode version."
fi

echo
echo "Tip: Use the UUID shown above as the device id for ./scripts/run-ios.sh <device-id>"
