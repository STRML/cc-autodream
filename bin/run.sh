#!/bin/bash
# Autodream runner — invoked by launchd at ~3am local time.
#
# Two-layer pipeline:
#   L1: For each of yesterday's session JSONLs, spawn a parallel `claude --model haiku`
#       running SESSION_TRIAGE.md → writes one findings.json per session.
#   L2: One `claude --model opus` running PROMPT.md → reads all findings JSONs,
#       writes $DREAMS_DIR/YYYY-MM-DD.md, updates project MEMORY.md files.
#
# Usage:
#   ./run.sh             # process yesterday
#   ./run.sh 2026-05-24  # process a specific date
#   FANOUT=4 ./run.sh    # tune L1 parallelism (default 8)
#
# Environment overrides (all optional):
#   CLAUDE_BIN     path to claude CLI                   default: $HOME/.local/bin/claude
#   PROJECTS_DIR   where session JSONLs live           default: $HOME/.claude/projects
#   AUTODREAM_DIR  scripts + prompts + state           default: $HOME/.claude/autodream
#   DREAMS_DIR     where final reports are written     default: $HOME/.claude/dreams
#   FANOUT         L1 parallelism                      default: 8

set -u

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
LOG_DIR="$AUTODREAM_DIR/logs"
FANOUT="${FANOUT:-8}"

TARGET_DATE="${1:-$(date -v-1d +%Y-%m-%d)}"
NEXT_DATE=$(date -j -f %Y-%m-%d -v+1d "$TARGET_DATE" +%Y-%m-%d)

FINDINGS_DIR="$AUTODREAM_DIR/findings/$TARGET_DATE"
REPORT_PATH="$DREAMS_DIR/$TARGET_DATE.md"
RUN_LOG="$LOG_DIR/run-$TARGET_DATE.log"
SESSIONS_LIST="$FINDINGS_DIR/sessions.txt"

mkdir -p "$FINDINGS_DIR" "$DREAMS_DIR" "$LOG_DIR"

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
cd "$HOME"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

run() {
  log "===== autodream start: $(date) ====="
  log "target date: $TARGET_DATE"
  log "findings:    $FINDINGS_DIR"
  log "report:      $REPORT_PATH"
  log "fanout:      $FANOUT"
  log "claude:      $CLAUDE_BIN"

  [ -x "$CLAUDE_BIN" ] || { log "FATAL: claude not at $CLAUDE_BIN"; exit 1; }

  # ---- Enumerate sessions modified during the target day ----
  log "scanning $PROJECTS_DIR for sessions modified between $TARGET_DATE and $NEXT_DATE..."
  find "$PROJECTS_DIR" -type f -name '*.jsonl' \
       -newermt "$TARGET_DATE 00:00:00" \
       ! -newermt "$NEXT_DATE 00:00:00" \
       2>/dev/null > "$SESSIONS_LIST"
  COUNT=$(wc -l < "$SESSIONS_LIST" | tr -d ' ')
  log "found $COUNT session files"

  if [ "$COUNT" -eq 0 ]; then
    log "no sessions to triage; writing stub report and exiting"
    cat > "$REPORT_PATH" <<EOF
# Autodream — $TARGET_DATE

No Claude Code sessions were modified on this date.

(Generated $(date -u +%Y-%m-%dT%H:%M:%SZ))
EOF
    return 0
  fi

  # ---- Layer 1: haiku triage, parallel ----
  log "L1 triage starting (fanout=$FANOUT)..."
  L1_START=$(date +%s)

  export CLAUDE_BIN AUTODREAM_DIR FINDINGS_DIR
  < "$SESSIONS_LIST" xargs -P "$FANOUT" -I {} bash -c '
    session="$1"
    hash=$(printf "%s" "$session" | shasum -a 1 | cut -c1-12)
    output="$FINDINGS_DIR/$hash.json"
    errlog="$output.err"

    [ -s "$output" ] && exit 0  # idempotent

    prompt=$(printf "SESSION_PATH=%s\nOUTPUT_PATH=%s\n\n" "$session" "$output")
    prompt="${prompt}$(cat "$AUTODREAM_DIR/SESSION_TRIAGE.md")"

    printf "%s" "$prompt" | "$CLAUDE_BIN" \
      --print \
      --permission-mode bypassPermissions \
      --model claude-haiku-4-5 \
      --append-system-prompt "Headless triage worker. Write JSON to OUTPUT_PATH via the Write tool. Print only the literal word done and exit." \
      > /dev/null 2> "$errlog"

    if [ -s "$output" ]; then
      rm -f "$errlog"
      echo "ok: $session ($hash)"
    else
      echo "FAIL: $session ($hash) — see $errlog" >&2
    fi
  ' _ {}

  L1_ELAPSED=$(( $(date +%s) - L1_START ))
  L1_OK=$(ls -1 "$FINDINGS_DIR"/*.json 2>/dev/null | wc -l | tr -d " ")
  L1_FAIL=$(ls -1 "$FINDINGS_DIR"/*.json.err 2>/dev/null | wc -l | tr -d " ")
  log "L1 done in ${L1_ELAPSED}s: $L1_OK ok, $L1_FAIL failed"

  # ---- Layer 2: opus aggregate ----
  log "L2 aggregation starting..."
  L2_START=$(date +%s)

  prompt=$(printf "FINDINGS_DIR=%s\nREPORT_PATH=%s\n\n" "$FINDINGS_DIR" "$REPORT_PATH")
  prompt="${prompt}$(cat "$AUTODREAM_DIR/PROMPT.md")"

  printf "%s" "$prompt" | "$CLAUDE_BIN" \
    --print \
    --permission-mode bypassPermissions \
    --model claude-opus-4-7 \
    --append-system-prompt "Headless aggregator. Read findings JSONs from FINDINGS_DIR. Write the report to REPORT_PATH via Write. May edit project MEMORY.md files per the prompt rules. Print report path and 3-line summary, then exit."

  L2_RC=$?
  L2_ELAPSED=$(( $(date +%s) - L2_START ))
  log "L2 done in ${L2_ELAPSED}s (exit $L2_RC)"

  if [ -f "$REPORT_PATH" ]; then
    log "report bytes: $(wc -c < "$REPORT_PATH" | tr -d ' ')"

    # ---- Drop open-questions file into Sublime (no-op if zero questions) ----
    if [ -x "$AUTODREAM_DIR/notify.sh" ]; then
      log "writing open-questions inbox file..."
      "$AUTODREAM_DIR/notify.sh" "$REPORT_PATH" || log "notify step returned non-zero (continuing)"
    fi

    # ---- Symbiotic GC: trigger cc-simple-memory to consolidate
    #      around the pins Layer 2 just added (no-op if not installed
    #      or AUTODREAM_GC=0). Iterates the touched-projects sidecar
    #      Layer 2 wrote — re-uses the cwd recorded in each project's
    #      session JSONLs to give claude-memory the right project root.
    if [ "${AUTODREAM_GC:-1}" != "0" ] && command -v claude-memory >/dev/null 2>&1; then
      TOUCHED="$FINDINGS_DIR/touched-projects.txt"
      if [ -s "$TOUCHED" ]; then
        log "claude-memory detected; running GC for $(wc -l < "$TOUCHED" | tr -d ' ') touched project(s)..."
        sort -u "$TOUCHED" | while IFS= read -r encoded; do
          [ -z "$encoded" ] && continue
          proj="$PROJECTS_DIR/$encoded"
          [ -d "$proj" ] || { log "  skip: $encoded (no project dir)"; continue; }

          cwd=$(grep -hom1 '"cwd":"[^"]*"' "$proj"/*.jsonl 2>/dev/null \
                 | head -1 | sed 's/^"cwd":"//;s/"$//')
          if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
            log "  skip: $encoded (cwd not resolvable)"
            continue
          fi
          log "  gc: $cwd"
          ( cd "$cwd" && claude-memory gc ) >> "$RUN_LOG" 2>&1 \
            || log "    gc failed for $cwd (continuing)"
        done
      else
        log "claude-memory installed but no project memory was touched; skipping per-project GC"
      fi
    fi
  else
    log "WARNING: no report at $REPORT_PATH"
  fi

  log "===== autodream end: $(date) ====="
  return $L2_RC
}

run 2>&1 | tee -a "$RUN_LOG"
exit ${PIPESTATUS[0]}
