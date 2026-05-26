#!/bin/bash
# Write the "Open questions" section of an autodream report to a text file
# and pop it open in Sublime Text. Quiet no-op if there are no questions.
#
# Usage: notify.sh <report.md>
#
# Environment overrides:
#   AUTODREAM_DIR  scripts + state           default: $HOME/.claude/autodream
#   SUBL           path to subl binary       default: tries $HOME/bin/subl then PATH

set -u

REPORT="${1:?Usage: notify.sh <report.md>}"
DATE=$(basename "$REPORT" .md)
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
INBOX_DIR="$AUTODREAM_DIR/inbox"
SUBL="${SUBL:-$HOME/bin/subl}"
[ -x "$SUBL" ] || SUBL=$(command -v subl || echo /Applications/Sublime\ Text.app/Contents/SharedSupport/bin/subl)

mkdir -p "$INBOX_DIR"

[ -f "$REPORT" ] || { echo "notify.sh: no such report: $REPORT" >&2; exit 1; }

QUESTIONS=$(awk '
  /^## Open questions for the user/ { capture=1; next }
  capture && /^## / { exit }
  capture && /^---[[:space:]]*$/ { exit }
  capture { print }
' "$REPORT")
QUESTIONS=$(printf "%s" "$QUESTIONS" | awk 'NF{p=1} p')
COUNT=$(printf "%s\n" "$QUESTIONS" | grep -cE '^[[:space:]]*[0-9]+\.' || true)

if [ -z "$QUESTIONS" ] || [ "$COUNT" -eq 0 ]; then
  echo "notify.sh: $DATE has 0 open questions; nothing to pop"
  exit 0
fi

OUT="$INBOX_DIR/$DATE-open-questions.md"
cat > "$OUT" <<EOF
# Autodream — $DATE
# $COUNT open question$([ "$COUNT" -eq 1 ] || echo s)
#
# Full report: $REPORT
# Triage interactively: $AUTODREAM_DIR/review.sh $DATE
#
# ────────────────────────────────────────────────────────

$QUESTIONS
EOF

if [ -x "$SUBL" ]; then
  "$SUBL" "$OUT"
  echo "notify.sh: opened $OUT in Sublime"
else
  echo "notify.sh: subl not found; wrote $OUT but did not open"
fi
