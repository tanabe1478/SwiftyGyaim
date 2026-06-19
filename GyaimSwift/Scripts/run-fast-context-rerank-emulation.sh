#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-Gyaim.xcodeproj}"
SCHEME="${SCHEME:-GyaimTests}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build}"
BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/${SCHEME}.xctest"
PROFILE_DIR="$DERIVED_DATA_PATH/Build/ProfileData"
ITERATIONS="${GYAIM_FAST_CONTEXT_EMULATION_ITERATIONS:-1000}"

mkdir -p "$PROFILE_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing

/usr/bin/xattr -cr "$BUNDLE" 2>/dev/null || true

LLVM_PROFILE_FILE="$PROFILE_DIR/${SCHEME}-fast-context-%p.profraw" \
GYAIM_FAST_CONTEXT_EMULATION_ITERATIONS="$ITERATIONS" \
GYAIM_FAST_CONTEXT_EMULATION_REPORT=1 \
  xcrun xctest \
  -XCTest Gyaim.FastContextRerankEmulationTests \
  "$BUNDLE"
