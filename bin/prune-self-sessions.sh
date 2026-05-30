#!/bin/bash
# Find (and optionally delete) autodream's OWN session transcripts.
#
# Every `claude --print` worker autodream spawns used to persist its own session
# JSONL into ~/.claude/projects/-Users-<you>/. The next night's run would then
# triage those as if they were real sessions — ~190 self-generated files/night,
# ~90% of the corpus, pure noise and wasted model spend. run.sh now passes
# --no-session-persistence so new runs leave no transcript, but older runs already
# littered the corpus; this script cleans them up and is also the single source of
# truth for the "is this one of ours?" predicate (run.sh calls `--filter`).
#
# Usage:
#   prune-self-sessions.sh                 # list self-sessions under $PROJECTS_DIR (dry run)
#   prune-self-sessions.sh --delete        # delete them
#   prune-self-sessions.sh --quiet         # just the summary line, no per-file paths
#   prune-self-sessions.sh /path/projects  # scan a specific projects dir
#   prune-self-sessions.sh --filter        # stdin: session paths; stdout: only NON-self ones
#
# Env:
#   PROJECTS_DIR   default $HOME/.claude/projects

set -u

# A session is autodream's own when its FIRST user turn is one of our inlined
# prompts. Anchored to the start of the message content so a human session that
# merely *discusses* autodream (mentions SESSION_PATH= mid-conversation) is NOT
# matched. Covers both the current literal-path framing and the legacy KEY=value
# framing from earlier runs.
SELF_RE='"content":"(Session transcript to analyze \(literal absolute path\)|Findings directory to aggregate \(literal absolute path\)|SESSION_PATH=|FINDINGS_DIR=)'

is_self() { # $1 = jsonl path → exit 0 if it's an autodream-generated session
  grep -m1 '"type":"user"' "$1" 2>/dev/null | grep -qE "$SELF_RE"
}

# ---- --filter: stdin paths -> stdout the ones we should still triage ----
if [ "${1:-}" = "--filter" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_self "$f" || printf '%s\n' "$f"
  done
  exit 0
fi

# ---- scan/list/delete ----
DELETE=0; QUIET=0; SCAN_DIR=""
for a in "$@"; do
  case "$a" in
    --delete) DELETE=1 ;;
    --quiet)  QUIET=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) SCAN_DIR="$a" ;;
  esac
done
PROJECTS_DIR="${SCAN_DIR:-${PROJECTS_DIR:-$HOME/.claude/projects}}"

[ -d "$PROJECTS_DIR" ] || { echo "no such projects dir: $PROJECTS_DIR" >&2; exit 1; }

count=0; bytes=0
while IFS= read -r f; do
  is_self "$f" || continue
  count=$((count + 1))
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' '); bytes=$((bytes + ${sz:-0}))
  [ "$QUIET" = 1 ] || echo "$f"
  [ "$DELETE" = 1 ] && rm -f "$f"
done < <(find "$PROJECTS_DIR" -type f -name '*.jsonl' 2>/dev/null)

mb=$(( bytes / 1048576 ))
if [ "$DELETE" = 1 ]; then
  echo "deleted $count autodream-own session file(s) (~${mb} MB) under $PROJECTS_DIR"
else
  echo "found $count autodream-own session file(s) (~${mb} MB) under $PROJECTS_DIR  (re-run with --delete to remove)"
fi
