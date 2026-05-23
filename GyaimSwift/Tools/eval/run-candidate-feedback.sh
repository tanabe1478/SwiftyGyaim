#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="${PROJECT:-Gyaim.xcodeproj}"
SCHEME="${SCHEME:-GyaimTests}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build}"
BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/${SCHEME}.xctest"
REPORT="${REPORT:-/tmp/gyaim-candidate-feedback-report.md}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing >/tmp/gyaim-candidate-feedback-build.log

/usr/bin/xattr -cr "$BUNDLE" 2>/dev/null || true
rm -f "$REPORT"

GYAIM_FEEDBACK_REPORT="$REPORT" \
xcrun xctest \
  -XCTest Gyaim.CandidatePipelineFeedbackTests \
  "$BUNDLE"

if [[ -f "$REPORT" ]]; then
  echo "wrote $REPORT"
  sed -n '1,160p' "$REPORT"
fi
