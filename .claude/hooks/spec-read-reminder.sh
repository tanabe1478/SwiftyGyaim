#!/bin/bash
# PreToolUse hook: Remind to read relevant spec before editing .swift files
# Fires on: Edit *.swift

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

SPECS_DIR="$REPO_ROOT/docs/specs"
if [ ! -d "$SPECS_DIR" ]; then
  exit 0
fi

# Read tool input from stdin
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  echo "$INPUT"
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# Map files to specs via Trigger lines
for spec in "$SPECS_DIR"/*.md; do
  [ -f "$spec" ] || continue
  triggers=$(head -5 "$spec" | grep '^> Trigger:' | sed 's/> Trigger: //')
  if [ -z "$triggers" ]; then
    continue
  fi
  if echo "$triggers" | grep -q "$BASENAME"; then
    spec_name=$(basename "$spec")
    echo "[Spec Reminder] $BASENAME を編集する前に docs/specs/$spec_name を確認してください" >&2
  fi
done

echo "$INPUT"
exit 0
