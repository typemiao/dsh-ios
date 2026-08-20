#!/bin/bash
# run-simulator.sh — build the iOS app for the simulator, install, launch,
# and stream the mirrored node console log (phase acceptance loop).
#
# Usage:
#   scripts/run-simulator.sh [phase] [device-name]
#     phase       : 1 (engine) | 2 (dsh core import) | 3 (dsh web + WKWebView)
#     device-name : simulator device name (default "iPhone 17 Pro")

set -euo pipefail

PHASE="${1:-1}"
DEVICE="${2:-iPhone 17 Pro}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ios-app"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> phase: $PHASE  device: $DEVICE"

# 1. regenerate the Xcode project (keeps project.yml as the source of truth)
(cd "$APP" && xcodegen generate)

# 2. build for the simulator (arm64 slice from NodeMobile.xcframework)
xcodebuild -project "$APP/DSHMobile.xcodeproj" \
  -scheme DSHMobile \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  build 2>&1 | tail -3

APP_PATH=$(find "$ROOT/.build/DerivedData/Build/Products" -name "DSHMobile.app" -type d | head -1)
echo "==> app: $APP_PATH"

# 3. boot the device + install + launch
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator || true
xcrun simctl install "$DEVICE" "$APP_PATH"
BUNDLE_ID="com.dsh.ios.DSHMobile"
echo "==> launching with DSH_IOS_PHASE=$PHASE"
SIMCTL_CHILD_DSH_IOS_PHASE="$PHASE" xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

# 4. tail the mirrored node console (Application Support inside the sandbox)
DATA_DIR=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data 2>/dev/null || true)
LOG="$DATA_DIR/Library/Application Support/node-console.log"
echo "==> tailing $LOG"
{ [ -f "$LOG" ] && : > "$LOG"; } || true
for i in $(seq 1 240); do
  if [ -f "$LOG" ]; then
    if grep -q "node up" "$LOG" 2>/dev/null || grep -q "FATAL" "$LOG" 2>/dev/null || grep -q "dsh web:" "$LOG" 2>/dev/null; then
      break
    fi
  fi
  sleep 1
done
echo "── node console ──"
tail -50 "$LOG" 2>/dev/null || echo "(no log yet)"

# 5. gate on the phase's success marker (CI needs a hard pass/fail)
case "$PHASE" in
  1) MARKER="node up" ;;
  2) MARKER="dsh core import OK" ;;
  3) MARKER="dsh web booted" ;;
  *) MARKER="" ;;
esac
if [ -n "$MARKER" ] && grep -q "$MARKER" "$LOG" 2>/dev/null; then
  echo "==> PHASE $PHASE OK (marker: $MARKER)"
else
  echo "==> PHASE $PHASE FAILED (marker '$MARKER' not found in console log)" >&2
  exit 1
fi
