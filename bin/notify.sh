#!/bin/bash
# Write the "Open questions" section of an autodream report to a text file, post a
# persistent macOS notification, and pop it open in Sublime Text. Quiet no-op if there
# are no questions.
#
# The banner is the reliable signal: the nightly run fires ~3am under launchd, when a
# GUI window open (subl) silently fails to surface. `display notification` posts to
# Notification Center, which persists until dismissed, so the alert is waiting whenever
# the Mac is next used. The subl open stays as a best-effort convenience on top.
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
# Count question items: L2 may format them as a numbered list ("1.") or as dash
# bullets grouped under bold subheadings ("- ..."). Match both, or notify silently
# no-ops on a report that is actually full of questions.
COUNT=$(printf "%s\n" "$QUESTIONS" | grep -cE '^[[:space:]]*([0-9]+\.|[-*])[[:space:]]' || true)

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

# Persistent banner first — survives the 3am launchd run regardless of GUI state.
# Best-effort: a notification failure must never break the run.
#
# terminal-notifier gives a CLICKABLE banner (-execute runs on click → opens the
# inbox file in Sublime). Plain osascript banners cannot carry a click action, so they
# are only the fallback when terminal-notifier is absent. -group collapses repeat
# notifications for the same date instead of stacking. NOTE: click-to-open requires
# terminal-notifier's notification style to be "Alerts" (not "Banners") in System
# Settings ▸ Notifications — banners can auto-dismiss before you click them.
plural=$([ "$COUNT" -eq 1 ] || echo s)
if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier \
    -title "Autodream — $DATE" \
    -message "$COUNT open question$plural — click to open" \
    -execute "open -a 'Sublime Text' '$OUT'" \
    -group "autodream-$DATE" \
    -sound Glass >/dev/null 2>&1 \
    && echo "notify.sh: posted clickable notification for $DATE ($COUNT open question$plural)" \
    || echo "notify.sh: terminal-notifier post failed (continuing)"
elif command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$COUNT open question$plural — see inbox\" with title \"Autodream — $DATE\" sound name \"Glass\"" >/dev/null 2>&1 \
    && echo "notify.sh: posted notification for $DATE ($COUNT open question$plural; install terminal-notifier for click-to-open)" \
    || echo "notify.sh: notification post failed (continuing)"
fi

if [ -x "$SUBL" ]; then
  "$SUBL" "$OUT"
  echo "notify.sh: opened $OUT in Sublime"
else
  echo "notify.sh: subl not found; wrote $OUT but did not open"
fi
