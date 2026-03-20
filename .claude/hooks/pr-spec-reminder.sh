#!/bin/bash
# Post-PR-creation hook: Remind about spec and bug-memory updates
# Fires on: gh pr create
# Output: JSON with hookSpecificOutput.additionalContext for Claude to see

INPUT=$(cat)

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "$INPUT"
  exit 0
fi

# Get all .swift files changed since branching from master
CHANGED=$(git diff --name-only master...HEAD 2>/dev/null | grep '\.swift$')
if [ -z "$CHANGED" ]; then
  echo "$INPUT"
  exit 0
fi

SPECS_DIR="$REPO_ROOT/docs/specs"
SPECS_CHANGED=$(git diff --name-only master...HEAD 2>/dev/null | grep '^docs/specs/')
BUG_MEMORY_CHANGED=$(echo "$SPECS_CHANGED" | grep 'bug-memory.md')

MSG="[PR Spec Check] Swift files changed: $(echo $CHANGED | tr '\n' ', '). "

if [ -z "$SPECS_CHANGED" ]; then
  MSG="${MSG}WARNING: No specs updated in this PR. Review docs/specs/ for updates needed. "
else
  MSG="${MSG}Specs updated: $(echo $SPECS_CHANGED | tr '\n' ', '). "
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BUG_MEMORY_CHANGED" ] && echo "$BRANCH" | grep -qi "fix"; then
  MSG="${MSG}This is a bug fix branch - consider adding entry to docs/specs/bug-memory.md. "
fi

cat <<ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "${MSG}"
  }
}
ENDJSON

exit 0
