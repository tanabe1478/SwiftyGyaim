#!/bin/bash
# Pre-commit hook: Check if changed .swift files have specs that may need updating
# Fires on: git commit
# Reads stdin (hook JSON payload) and passes it through

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

# Get both staged and unstaged .swift files (Claude Code may not stage before PreToolUse fires)
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
      spec_date=$(head -5 "$spec" | grep '^> Last updated:' | sed 's/> Last updated: //')
      today=$(date +%Y-%m-%d)
      stale=""
      if [ "$spec_date" != "$today" ]; then
        stale=" ⚠️ STALE"
      fi
      SPECS_TO_CHECK="$SPECS_TO_CHECK\n  - $spec_name (last updated: $spec_date$stale) ← triggered by $file_basename"
    fi
  done
done

if [ -n "$SPECS_TO_CHECK" ]; then
  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "[Spec Check] The following specs may need updating:" >&2
  echo -e "$SPECS_TO_CHECK" >&2
  echo "" >&2
  echo "[Spec Check] If you made behavioral changes, update the relevant spec in docs/specs/" >&2
  echo "[Spec Check] If you fixed a bug, add an entry to docs/specs/bug-memory.md" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
fi

echo "$INPUT"
exit 0
