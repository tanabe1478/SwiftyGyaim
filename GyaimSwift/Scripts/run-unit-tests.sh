#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-Gyaim.xcodeproj}"
SCHEME="${SCHEME:-GyaimTests}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build}"
BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/${SCHEME}.xctest"
PROFILE_DIR="$DERIVED_DATA_PATH/Build/ProfileData"

mkdir -p "$PROFILE_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing

# Local macOS/Xcode combinations can attach com.apple.provenance to freshly
# built .xctest bundles. In that state `xcodebuild test` may report
# "Cannot find executable for CFBundle" even when Contents/MacOS/<test> exists.
# Running the already-built bundle with xcrun xctest after clearing xattrs avoids
# the loader failure while keeping the same XCTest bundle.
/usr/bin/xattr -cr "$BUNDLE" 2>/dev/null || true

LLVM_PROFILE_FILE="$PROFILE_DIR/${SCHEME}-%p.profraw" \
  xcrun xctest "$BUNDLE"
