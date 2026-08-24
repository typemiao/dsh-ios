#!/bin/bash
# run-simulator.sh -- build the iOS app for the simulator, install, launch,
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
# xcodegen >=2.45 writes objectVersion 77 (Xcode 26), which the runner's
# Xcode 15.4 refuses to open — force the Xcode-15 format.
sed -i '' -E 's/objectVersion = [0-9]+;/objectVersion = 56;/' \
  "$APP/DSHMobile.xcodeproj/project.pbxproj"
sed -i '' '/preferredProjectObjectVersion/d' \
  "$APP/DSHMobile.xcodeproj/project.pbxproj"

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
BUNDLE_ID="com.typemiao.dshmobile"
echo "==> launching with DSH_IOS_PHASE=$PHASE"
SIMCTL_CHILD_DSH_IOS_PHASE="$PHASE" xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

# 4. wait for the phase OUTCOME (success marker OR a fatal boot error), then
#    dump the FULL console log — tailing right after 'node up' would miss the
#    boot failure that develops later.
case "$PHASE" in
  1) MARKER="node up" ;;
  2) MARKER="dsh core import OK" ;;
  3) MARKER="dsh web booted" ;;
  *) MARKER="" ;;
esac
DATA_DIR=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data 2>/dev/null || true)
LOG="$DATA_DIR/Library/Application Support/node-console.log"
echo "==> waiting for outcome in $LOG"
# First launch expands ~300 MiB / tens of thousands of payload entries.
for i in $(seq 1 600); do
  if [ -f "$LOG" ]; then
    if grep -q "$MARKER" "$LOG" 2>/dev/null || grep -q "FATAL" "$LOG" 2>/dev/null; then
      break
    fi
  fi
  sleep 1
done
echo "---- node console (full) ----"
if [ -f "$LOG" ]; then cat "$LOG" 2>/dev/null || echo "(unreadable)"; else echo "(no log at $LOG)"; fi
echo "---- other node-console.log locations ----"
find "$DATA_DIR" -name 'node-console.log' 2>/dev/null | head -5 || true
echo "---- dsh-probe (if any) ----"
find "$DATA_DIR" -name 'dsh-probe.txt' 2>/dev/null | while read -r f; do
  echo "== $f =="; cat "$f" 2>/dev/null || true
done
echo "---- dsh-swift-probe (if any) ----"
find "$DATA_DIR" -name 'dsh-swift-probe.txt' 2>/dev/null | while read -r f; do
  echo "== $f =="; cat "$f" 2>/dev/null || true
done
echo "---- dsh-runtime dir (if any) ----"
find "$DATA_DIR" -type d -name 'dsh-runtime' 2>/dev/null | head -1 | while read -r d; do echo "$d"; ls -la "$d" 2>/dev/null | head -8 || true; done

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
