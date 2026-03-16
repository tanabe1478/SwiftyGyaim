#!/bin/bash
# Post-PR-creation hook: Remind about spec and bug-memory updates
# Fires on: gh pr create

# Read stdin (hook payload)
INPUT=$(cat)

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "$INPUT"
  exit 0
fi

# Get all files changed since branching from master
CHANGED=$(git diff --name-only master...HEAD 2>/dev/null | grep '\.swift$')
if [ -z "$CHANGED" ]; then
  echo "$INPUT"
  exit 0
fi

SPECS_DIR="$REPO_ROOT/docs/specs"
SPECS_CHANGED=$(git diff --name-only master...HEAD 2>/dev/null | grep '^docs/specs/')
BUG_MEMORY_CHANGED=$(echo "$SPECS_CHANGED" | grep 'bug-memory.md')

echo "" >&2
echo "[PR Spec Check] Swift files changed in this PR:" >&2
for f in $CHANGED; do
  echo "  - $f" >&2
done

if [ -z "$SPECS_CHANGED" ]; then
  echo "" >&2
  echo "[PR Spec Check] WARNING: No specs were updated in this PR." >&2
  echo "[PR Spec Check] Review docs/specs/ for any specs that need updating." >&2
else
  echo "" >&2
  echo "[PR Spec Check] Specs updated: $SPECS_CHANGED" >&2
fi

if [ -z "$BUG_MEMORY_CHANGED" ]; then
  # Check if this looks like a bug fix branch
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if echo "$BRANCH" | grep -qi "fix"; then
    echo "" >&2
    echo "[PR Spec Check] This appears to be a bug fix branch." >&2
    echo "[PR Spec Check] Consider adding an entry to docs/specs/bug-memory.md" >&2
  fi
fi

echo "$INPUT"
exit 0
