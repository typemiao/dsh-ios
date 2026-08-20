#!/bin/bash
# build-nodejs-mobile.sh
#
# Build the Node 22.9 iOS xcframework from the capawesome nodejs-mobile fork
# (https://github.com/capawesome-team/nodejs-mobile, branch update22-9-0).
#
# Why from source: dsh requires Node ^22.19 || >=24 (packages/dsh root engines),
# and every published nodejs-mobile release is Node 12/16/18 -- too old. The
# capawesome fork carries a Node 22.9 branch whose CI builds iOS with Xcode 15;
# we reproduce that build locally (M4 -> arm64 only, so x64-simulator is skipped;
# that slice would need Rosetta and is never used on Apple Silicon simulators).
#
# JIT: the iOS build passes --v8-options=--jitless (default in nodejs-mobile),
# which matches the milestone: jitless boot first, JIT later via StikDebug.
#
# Output: <repo>/NodeMobile.xcframework (two slices: ios-arm64, ios-arm64-simulator)
#
# Requires: Xcode + Command Line Tools, python3 (3.9+ with distutils is fine).

set -euo pipefail

REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)/nodejs-mobile}"
OUT="${2:-$(cd "$(dirname "$0")/.." && pwd)/deps}"

echo "==> nodejs-mobile repo: $REPO"
echo "==> output dir:        $OUT"

# Clone BEFORE cd -- on a fresh checkout nodejs-mobile/ does not exist yet.
if [ ! -f "$REPO/configure" ]; then
  echo "==> cloning capawesome nodejs-mobile (branch update22-9-0) into $REPO ..."
  # GitHub can transiently fail a shallow clone ("error processing shallow
  # info"); retry, then fall back to a full single-branch clone.
  for attempt in 1 2 3; do
    if git clone --depth 1 --branch update22-9-0 https://github.com/capawesome-team/nodejs-mobile.git "$REPO"; then
      break
    fi
    echo "==> shallow clone attempt $attempt failed - retrying"
    rm -rf "$REPO"
    sleep 5
  done
  if [ ! -d "$REPO/.git" ]; then
    echo "==> falling back to full single-branch clone"
    git clone --single-branch --branch update22-9-0 https://github.com/capawesome-team/nodejs-mobile.git "$REPO"
  fi
  # Pin the exact commit the patches/ were built against (update22-9-0 tip at
  # handover). If upstream moves the branch, deepen the history and check out
  # the pinned commit; if even that fails, the git apply step below reports it.
  (cd "$REPO" && \
   if [ "$(git rev-parse HEAD)" != "106c51f9" ]; then \
     git fetch --shallow-since=2026-01-01 origin update22-9-0 && git checkout -q 106c51f9; \
   fi) || true
fi
cd "$REPO"

# -- apply the iOS build patches ---------------------------------------------
# The update22-9-0 branch does not build for iOS as-is (its tip commit is
# literally "Try adding ios..."). patches/nodejs-mobile-ios.patch carries the
# full diff fixing: the host-tool iOS-SDK leak, the 7 missing Node 22 static
# libs in the framework project, the libbase64 removal, and the two missing
# V8 sources (platform-ios.cc jitless stub + abseil
# crc_non_temporal_memcpy.cc). Idempotent: on an already-patched (resumable)
# build tree it simply doesn't apply a second time and we continue.
PATCH_DIR="$(cd "$(dirname "$0")/.." && pwd)/patches"
if git apply --check "$PATCH_DIR/nodejs-mobile-ios.patch" 2>/dev/null; then
  git apply "$PATCH_DIR/nodejs-mobile-ios.patch"
  echo "==> applied patches/nodejs-mobile-ios.patch"
else
  echo "==> patches already applied (or upstream drifted) -- verify: git diff --stat"
fi

# Refresh the reference .patched copies so they mirror the live tree.
cp tools/ios_framework_prepare.sh "$PATCH_DIR/ios_framework_prepare.sh.patched"
cp tools/ios-framework/NodeMobile.xcodeproj/project.pbxproj "$PATCH_DIR/NodeMobile.pbxproj.patched"
cp tools/v8_gypfiles/v8.gyp "$PATCH_DIR/v8.gyp.patched"
cp deps/v8/src/base/platform/platform-ios.cc "$PATCH_DIR/platform-ios.cc.patched"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Node's gyp configure needs distutils, which Python 3.12+ removed (GitHub
# Actions runners ship 3.12/3.13). Fall back to a throwaway venv with
# setuptools (it installs a distutils shim), like nodejs-mobile's own CI.
if ! python3 -c 'import distutils' >/dev/null 2>&1; then
  echo "==> python3 lacks distutils -- creating venv with setuptools"
  python3 -m venv .ci-venv
  # shellcheck disable=SC1091
  . .ci-venv/bin/activate
  python3 -m pip install --quiet setuptools
fi

# ARCH_ONLY splits the pipeline for GitHub Actions (each slice on its own
# runner, keeping disk/time per job low):
#   ""              -> full local flow (device + simulator + combine)
#   arm64           -> device slice only
#   arm64-simulator -> simulator slice only
# The combine step runs separately on the app job (inline xcodebuild).
if [ -z "${ARCH_ONLY:-}" ] || [ "$ARCH_ONLY" = "arm64" ]; then
  echo "==> [1/3] build arm64 device libnode + framework"
  ./tools/ios_framework_prepare.sh arm64
fi

if [ -z "${ARCH_ONLY:-}" ] || [ "$ARCH_ONLY" = "arm64-simulator" ]; then
  echo "==> [2/3] build arm64-simulator libnode + framework"
  ./tools/ios_framework_prepare.sh arm64-simulator
fi

if [ -z "${ARCH_ONLY:-}" ]; then
  echo "==> [3/3] combine into NodeMobile.xcframework (device + arm64 simulator)"
  mkdir -p out_ios
  rm -rf "$OUT/NodeMobile.xcframework"
  xcodebuild -create-xcframework \
    -framework out_ios_arm64/iphoneos-arm64/Release-iphoneos/NodeMobile.framework \
    -framework out_ios_arm64-simulator/iphonesimulator-arm64/Release-iphonesimulator/NodeMobile.framework \
    -output "$OUT/NodeMobile.xcframework"

  echo "==> done: $OUT/NodeMobile.xcframework"
  find "$OUT/NodeMobile.xcframework" -maxdepth 2 -type d | sort
fi
