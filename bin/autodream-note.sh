#!/usr/bin/env bash
# autodream-note.sh — leave a free-text note for the next cc-autodream run.
#
# The L2 aggregator reads ~/.claude/autodream/notes.md and addresses each active note in
# its "Operator notes" report section (usage counts, is-it-working reads, etc.). Notes
# past their --expires date are ignored and flagged for removal, so the file self-retires.
#
# Usage:
#   autodream-note.sh "evaluate how often /graphify is used"
#   autodream-note.sh --expires 2026-10-01 "evaluate how well graphify works"
set -euo pipefail

NOTES="$HOME/.claude/autodream/notes.md"
EXPIRES=""
if [ "${1:-}" = "--expires" ]; then EXPIRES="${2:-}"; shift 2; fi
TEXT="${*:-}"
[ -n "$TEXT" ] || { echo "usage: autodream-note.sh [--expires YYYY-MM-DD] \"note text\"" >&2; exit 2; }

mkdir -p "$(dirname "$NOTES")"
if [ ! -f "$NOTES" ]; then
  printf '# Operator notes for autodream\n\nFree-text notes the next run should address in its "Operator notes" section.\nFormat: `- [added] (expires DATE) text` — expiry optional; expired notes are ignored.\n\n' > "$NOTES"
fi

TODAY="$(date +%F)"
if [ -n "$EXPIRES" ]; then
  printf -- '- [%s] (expires %s) %s\n' "$TODAY" "$EXPIRES" "$TEXT" >> "$NOTES"
else
  printf -- '- [%s] %s\n' "$TODAY" "$TEXT" >> "$NOTES"
fi
echo "noted -> $NOTES"
