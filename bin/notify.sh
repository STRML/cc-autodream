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

# Resolve the notifier. Prefer our rebranded bundle so banners read "cc-autodream"
# instead of "terminal-notifier"; bootstrap it once via make-notifier.sh if it's
# missing but terminal-notifier is installed. Fall back to plain terminal-notifier,
# then to an osascript banner (not clickable). Resolve make-notifier.sh next to this
# script (repo + ~/.claude/autodream symlink both work), then the install dir.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAKE_NOTIFIER="$SCRIPT_DIR/make-notifier.sh"
[ -x "$MAKE_NOTIFIER" ] || MAKE_NOTIFIER="$AUTODREAM_DIR/make-notifier.sh"
BRANDED="$AUTODREAM_DIR/cc-autodream.app/Contents/MacOS/terminal-notifier"
if [ ! -x "$BRANDED" ] && command -v terminal-notifier >/dev/null 2>&1 && [ -x "$MAKE_NOTIFIER" ]; then
  "$MAKE_NOTIFIER" >/dev/null 2>&1 || true
fi
NOTIFIER=""
[ -x "$BRANDED" ] && NOTIFIER="$BRANDED" || NOTIFIER="$(command -v terminal-notifier || true)"

mkdir -p "$INBOX_DIR"

[ -f "$REPORT" ] || { echo "notify.sh: no such report: $REPORT" >&2; exit 1; }

QUESTIONS=$(awk '
  /^## Open questions for the user/ { capture=1; next }
  capture && /^## / { exit }
  capture && /^---[[:space:]]*$/ { exit }
  capture { print }
' "$REPORT")
QUESTIONS=$(printf "%s" "$QUESTIONS" | awk 'NF{p=1} p')
# Count QUESTIONS, not list lines. L2 has emitted this section as a numbered list
# ("1."), as dash bullets under bold subheadings, as plain bullets, and as bare
# prose. Counting every list marker in one pass overcounts (sub-bullets under a
# numbered item, detail bullets under a bold title), and prose counts zero — which
# silently skips the pop on a report that actually has questions. So: take the
# first format tier that matches, and treat any other non-empty section as one
# question — a non-empty section must always pop.
count_matching(){ printf "%s\n" "$QUESTIONS" | grep -cE "$1" || true; }
COUNT=$(count_matching '^[[:space:]]*[0-9]+\.[[:space:]]')            # numbered items
[ "$COUNT" -eq 0 ] && COUNT=$(count_matching '^\*\*.+\*\*')           # bold titles
[ "$COUNT" -eq 0 ] && COUNT=$(count_matching '^[[:space:]]*[-*][[:space:]]')  # bullets
[ "$COUNT" -eq 0 ] && [ -n "$QUESTIONS" ] && COUNT=1                  # bare prose

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

# Persistent banner — survives the 3am launchd run regardless of GUI state.
# Best-effort: a notification failure must never break the run.
#
# Resilience note (learned the hard way, 2026-06): a banner's exit code does NOT prove it
# was shown. If the sender's notification permission is off — or a Focus/Do-Not-Disturb
# suppresses it — macOS silently drops the banner to Notification Center and the command
# still exits 0. The branded cc-autodream.app bundle is its OWN sender, so when branding
# was introduced macOS treated it as a new app defaulting to notifications-off, and every
# nightly banner vanished for a week while the log read "posted". That auth state is
# TCC-protected and unreadable from a script, so we cannot detect the drop.
#
# Defense: fire BOTH senders. terminal-notifier gives the CLICKABLE, branded banner
# (-execute opens the inbox in Sublime; -group collapses repeats). osascript posts through
# the system's already-trusted sender as a backup floor, so one blacked-out sender can't
# black out the whole alert. The osascript backup is silent (no -sound) to avoid a double
# chime when both land; set AUTODREAM_NOTIFY_OSA_BACKUP=0 to suppress the backup entirely.
# NOTE: for click-to-open, the cc-autodream sender's style must be "Alerts" (not "Banners",
# which auto-dismiss) in System Settings ▸ Notifications, and allowed through any Focus.
plural=$([ "$COUNT" -eq 1 ] || echo s)
OSA_BACKUP="${AUTODREAM_NOTIFY_OSA_BACKUP:-1}"
posted=0

if [ -n "$NOTIFIER" ]; then
  "$NOTIFIER" \
    -title "Autodream — $DATE" \
    -message "$COUNT open question$plural — click to open" \
    -execute "open -a 'Sublime Text' '$OUT'" \
    -group "autodream-$DATE" \
    -sound Glass >/dev/null 2>&1 \
    && { echo "notify.sh: posted clickable notification for $DATE ($COUNT open question$plural)"; posted=1; } \
    || echo "notify.sh: terminal-notifier post failed (continuing)"
fi

# osascript is the primary when there's no terminal-notifier, otherwise the backup sender.
if command -v osascript >/dev/null 2>&1 && { [ -z "$NOTIFIER" ] || [ "$OSA_BACKUP" != "0" ]; }; then
  if [ -n "$NOTIFIER" ]; then osa_sound=""; osa_role="backup"; else osa_sound=' sound name "Glass"'; osa_role="primary"; fi
  osascript -e "display notification \"$COUNT open question$plural — see inbox\" with title \"Autodream — $DATE\"$osa_sound" >/dev/null 2>&1 \
    && { echo "notify.sh: posted osascript $osa_role banner for $DATE"; posted=1; } \
    || echo "notify.sh: osascript notification post failed (continuing)"
fi

[ "$posted" -eq 1 ] || echo "notify.sh: WARNING no banner posted for $DATE (inbox written to $OUT)"

if [ -x "$SUBL" ]; then
  "$SUBL" "$OUT"
  echo "notify.sh: opened $OUT in Sublime"
else
  echo "notify.sh: subl not found; wrote $OUT but did not open"
fi
