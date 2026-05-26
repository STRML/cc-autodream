#!/bin/bash
# Open an interactive Claude session with the latest autodream report preloaded
# and instructions to walk through the open questions one at a time.
#
# Usage: review.sh             # opens latest report
#        review.sh YYYY-MM-DD  # opens specific report

set -u

DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

if [ $# -gt 0 ]; then
  REPORT="$DREAMS_DIR/$1.md"
else
  REPORT=$(ls -t "$DREAMS_DIR"/*.md 2>/dev/null | head -1)
fi

if [ -z "${REPORT:-}" ] || [ ! -f "$REPORT" ]; then
  echo "review.sh: no autodream report found"
  echo "  looked in: $DREAMS_DIR"
  echo "  try: $(dirname "$0")/run.sh"
  exit 1
fi

DATE=$(basename "$REPORT" .md)
REPORT_BYTES=$(wc -c < "$REPORT" | tr -d ' ')

# Build system prompt via tmpfile — heredocs inside $(...) get confused by
# apostrophes in the body (parser treats them as quote pairs and a literal
# `)` in the text prematurely closes the command substitution).
SYSTEM_TMP=$(mktemp -t autodream-review.XXXXXX)
trap 'rm -f "$SYSTEM_TMP"' EXIT
cat > "$SYSTEM_TMP" <<EOF
You are the morning autodream review partner. The user has opened this terminal session to triage open questions from last night's autodream run. The full report from $DATE follows — keep it in context but DO NOT dump it back to the user.

<autodream-report date="$DATE" path="$REPORT" bytes="$REPORT_BYTES">
$(cat "$REPORT")
</autodream-report>

Workflow when the user says "go" or otherwise signals ready:

1. Restate ONE open question (in order from the report's "Open questions for the user" section).
2. Cite the specific findings driving it (one-sentence summary, plus the section number in the report).
3. Recommend a concrete action. Be opinionated — the user trusts your judgment.
4. Wait for: approve / modify / skip / discuss.
5. If approved: execute (run shell commands, edit files — you have bypassPermissions). If modified: incorporate the change, confirm, then execute. If skipped or discussed: log the decision in a one-line follow-up comment at the bottom of $REPORT under a "## Triage decisions" section (create if absent).
6. Move to the next question. Don't batch multiple questions in one turn.

When all open questions are resolved, write a brief summary at the bottom of $REPORT under "## Triage decisions", thank the user, and exit.

Other rules:
- You may edit any file the autodream prompt allows you to edit (project MEMORY.md, settings.json, .claude/* in the relevant project), plus you may now edit ~/.claude/CLAUDE.md and ~/.claude/rules/* if the user explicitly approves.
- Don't proceed on any CLAUDE.md / rules edit without explicit per-edit approval — those are global.
- Be terse. One question, one decision, one action, then next.
EOF
SYSTEM=$(cat "$SYSTEM_TMP")
rm -f "$SYSTEM_TMP"
trap - EXIT

echo "─── autodream review: $DATE ($REPORT_BYTES bytes) ───"
echo "Starting triage. /quit to exit."
echo

cd "$HOME"
exec "$CLAUDE_BIN" \
  --permission-mode bypassPermissions \
  --append-system-prompt "$SYSTEM" \
  "go"
