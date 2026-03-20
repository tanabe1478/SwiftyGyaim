#!/bin/bash
# Pre-commit hook: Check if changed .swift files have specs that may need updating
# Fires on: git commit
# Output: JSON with hookSpecificOutput.additionalContext for Claude to see

INPUT=$(cat)

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "$INPUT"
  exit 0
fi

SPECS_DIR="$REPO_ROOT/docs/specs"
if [ ! -d "$SPECS_DIR" ]; then
  echo "$INPUT"
  exit 0
fi

# Get both staged and unstaged .swift files
CHANGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep '\.swift$')
if [ -z "$CHANGED" ]; then
  CHANGED=$(git diff --name-only 2>/dev/null | grep '\.swift$')
fi
if [ -z "$CHANGED" ]; then
  echo "$INPUT"
  exit 0
fi

# Map files to specs via Trigger lines
SPECS_TO_CHECK=""
TODAY=$(date +%Y-%m-%d)
for spec in "$SPECS_DIR"/*.md; do
  [ -f "$spec" ] || continue
  triggers=$(head -5 "$spec" | grep '^> Trigger:' | sed 's/> Trigger: //')
  if [ -z "$triggers" ]; then
    continue
  fi
  for changed_file in $CHANGED; do
    file_basename=$(basename "$changed_file")
    if echo "$triggers" | grep -q "$file_basename"; then
      spec_name=$(basename "$spec")
      spec_date=$(head -5 "$spec" | grep '^> Last updated:' | sed 's/> Last updated: //' | sed 's/ .*//')
      stale=""
      if [ "$spec_date" != "$TODAY" ]; then
        stale=" (STALE)"
      fi
      SPECS_TO_CHECK="${SPECS_TO_CHECK}${spec_name}${stale} <- ${file_basename}; "
    fi
  done
done

if [ -n "$SPECS_TO_CHECK" ]; then
  cat <<ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "[Spec Freshness] コミット前に確認: ${SPECS_TO_CHECK}動作仕様を変更した場合は対応specを同じコミットで更新すること。バグ修正の場合はbug-memory.mdにエントリを追記すること。"
  }
}
ENDJSON
else
  echo "$INPUT"
fi

exit 0
