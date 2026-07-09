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

python3 -m py_compile \
  Tools/ai-rerank/validate-fast-context-eval-cases.py \
  Tools/ai-rerank/evaluate-fast-context-rerank.py \
  Tools/ai-rerank/extract-fast-context-review-cases.py \
  Tools/ai-rerank/summarize-fast-context-review-labels.py \
  Tools/ai-rerank/sweep-fast-context-weights.py \
  Tools/ai-rerank/aggregate-fast-context-log.py \
  Tools/ai-rerank/train-fast-context-weights.py \
  Tools/zenz-tuning/compare-hf-gguf.py \
  Tools/dict/suggest-connection-entries.py \
  Tools/ai-rerank/extract-preference-pairs.py \
  Tools/dict/find-suspect-study-entries.py
python3 Tools/ai-rerank/validate-fast-context-eval-cases.py >/dev/null
python3 Tools/ai-rerank/evaluate-fast-context-rerank.py --json >/dev/null
# Quality gate (issue #57): fail CI when a non-model-required case misses top1,
# any case has an unsafe top, or a protected-exact candidate is demoted.
python3 Tools/ai-rerank/evaluate-fast-context-rerank.py --gate >/dev/null
python3 Tools/ai-rerank/evaluate-fast-context-rerank.py --feature-weight contextPredictionBonus=1.0 --json >/dev/null
python3 Tools/ai-rerank/sweep-fast-context-weights.py --limit 1 >/dev/null
python3 Tools/ai-rerank/train-fast-context-weights.py --epochs 3 --json >/dev/null
sweep_json="$(mktemp)"
python3 Tools/ai-rerank/sweep-fast-context-weights.py --json --limit 1 > "$sweep_json"
python3 - "$sweep_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    report = json.load(f)
assert "baseline" in report
assert "sweepSummary" in report
assert report["sweepSummary"]["totalWeightSets"] > 0
assert report["results"]
assert "delta" in report["results"][0]
PY
rm -f "$sweep_json"
suspect_dir="$(mktemp -d)"
printf 'sitehosii\tしてほしい\t1783274307.0\t22\nsitehosiii\tしてほしいい\t1773975120.0\t1\n' > "$suspect_dir/study.txt"
suspect_out="$(python3 Tools/dict/find-suspect-study-entries.py --study "$suspect_dir/study.txt" --format tsv)"
echo "$suspect_out" | grep -q "してほしいい" || { echo "suspect smoke failed: missing garbage completion"; exit 1; }
echo "$suspect_out" | grep -qv $'\tしてほしい\tgarbage-completion' || true
rm -rf "$suspect_dir"
pref_dir="$(mktemp -d)"
printf '[2026-07-10 10:00:00] [input] [info] Fast context accepted detail: input="kousin" payload={"chosenRank":2,"context":"アプリを","top":[{"kind":"raw","rank":0,"word":"kousin"},{"kind":"exact","rank":1,"reading":"kousin","source":"study","studyFrequency":11,"word":"行進"},{"contextAffinity":0.75,"kind":"exact","rank":2,"reading":"kousinn","source":"study","studyFrequency":101,"word":"更新"}]}\n' > "$pref_dir/log.txt"
python3 Tools/ai-rerank/extract-preference-pairs.py --log "$pref_dir/log.txt" > "$pref_dir/pref.jsonl" 2>/dev/null
grep -q '"expectedTop": "更新"' "$pref_dir/pref.jsonl" || { echo "preference extraction smoke failed"; exit 1; }
python3 Tools/ai-rerank/train-fast-context-weights.py "$pref_dir/pref.jsonl" --epochs 2 --json >/dev/null
rm -rf "$pref_dir"
suggest_dir="$(mktemp -d)"
printf 'kyokusho\t局所\t3\t4\nka\t*化\t4\t40\n' > "$suggest_dir/dict.txt"
printf 'kyokushoka\t局所化\t100.0\t9\nzeijaku\t脆弱\t100.0\t7\n' > "$suggest_dir/study.txt"
: > "$suggest_dir/local.txt"
: > "$suggest_dir/log.txt"
suggest_out="$(python3 Tools/dict/suggest-connection-entries.py --dict "$suggest_dir/dict.txt" \
  --study "$suggest_dir/study.txt" --local "$suggest_dir/local.txt" --log "$suggest_dir/log.txt" --format tsv)"
echo "$suggest_out" | grep -q "脆弱" || { echo "dict suggestion smoke failed: missing gap"; exit 1; }
echo "$suggest_out" | grep -q "局所化" && { echo "dict suggestion smoke failed: composable word suggested"; exit 1; }
rm -rf "$suggest_dir"
review_cases_jsonl="$(mktemp)"
python3 Tools/ai-rerank/extract-fast-context-review-cases.py --limit 1 > "$review_cases_jsonl"
python3 Tools/ai-rerank/summarize-fast-context-review-labels.py "$review_cases_jsonl" >/dev/null
rm -f "$review_cases_jsonl"
