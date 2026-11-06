#!/usr/bin/env bash
# Score the log-reconstructed context cases with a GGUF through the production
# ranking (ContextCasesEvaluationTests). Latency numbers are only meaningful
# with CONFIGURATION=Release (the default here).
#
#   Tools/eval/run-context-cases-eval.sh [report.json]
#   GYAIM_CONTEXT_EVAL_MODEL=/path/model.gguf GYAIM_CONTEXT_EVAL_SUBSET=gap30 Tools/eval/run-context-cases-eval.sh
# Optional private case diagnostics: GYAIM_CONTEXT_EVAL_TRACE=/new/path/trace.jsonl
# See Tools/model-training/NATIVE-ANALYSIS.md. Trace timing is diagnostic only.
set -euo pipefail
cd "$(dirname "$0")/../.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/GyaimTests.xctest"
OUTPUT="${1:-${TMPDIR:-/tmp}/gyaim-context-eval-report.json}"

xcodebuild -project Gyaim.xcodeproj -scheme GyaimTests -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" build-for-testing -quiet
/usr/bin/xattr -cr "$BUNDLE" 2>/dev/null || true
GYAIM_CONTEXT_EVAL=1 GYAIM_CONTEXT_EVAL_OUT="$OUTPUT" \
  xcrun xctest -XCTest ContextCasesEvaluationTests "$BUNDLE" 2>&1 | grep -vE '^\s*$'
echo "report: $OUTPUT"
