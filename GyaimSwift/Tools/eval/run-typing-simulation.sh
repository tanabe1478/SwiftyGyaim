#!/usr/bin/env bash
# Replay Tools/eval/typing-corpus.jsonl through TypingSimulationTests and write a
# JSON report. Uses temp dictionaries only; set GYAIM_TYPING_SIM_STUDYDICT to
# start from a copy of a study dict, GYAIM_TYPING_SIM_EPOCHS to replay N times.
set -euo pipefail
cd "$(dirname "$0")/../.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build}"
BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/GyaimTests.xctest"
OUTPUT="${1:-${TMPDIR:-/tmp}/gyaim-typing-sim-report.json}"

xcodebuild -project Gyaim.xcodeproj -scheme GyaimTests -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing -quiet
/usr/bin/xattr -cr "$BUNDLE" 2>/dev/null || true
GYAIM_TYPING_SIM=1 GYAIM_TYPING_SIM_OUTPUT="$OUTPUT" \
  xcrun xctest -XCTest TypingSimulationTests "$BUNDLE"
python3 Tools/eval/summarize-typing-simulation.py "$OUTPUT"
