#!/bin/bash
# Integration tests for cc-autodream's bin/run.sh.
#
# Drives the real run.sh end-to-end against a mock claude binary and fixture
# session files, then asserts on the output tree. No network, no model calls.
# macOS only (BSD `date`/`touch`), like the rest of the project.
#
# Usage:  tests/run-all.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
RUN="$REPO/bin/run.sh"
MOCK="$HERE/mock-claude.sh"
DATE=2020-01-02          # fixed target date; sessions are touched into this day
STAMP=202001021200       # touch -t form of DATE at noon

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_file(){     [ -f "$1" ] && ok "$2" || no "$2 (missing: $1)"; }
assert_no_file(){  [ ! -e "$1" ] && ok "$2" || no "$2 (unexpected: $1)"; }
assert_nonempty(){ [ -s "$1" ] && ok "$2" || no "$2 (empty/missing: $1)"; }
assert_grep(){     grep -q "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){   grep -q "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }
assert_eq(){       [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# Fresh sandbox: projects/ (session inputs) + autodream/ (prompts + state) + dreams/.
setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/proj-a" "$root/autodream" "$root/dreams" "$root/cap"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$root/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$root/autodream/PROMPT.md"
  printf '%s' "$root"
}
mk_session(){ # $1=root $2=name
  # Two real user turns (no timestamps -> duration_minutes 0, uncomputable and
  # so exempt from the duration gate rule) so this fixture clears the noise
  # gate's default AUTODREAM_MIN_USER_TURNS=2 floor and every existing test
  # that expects real L1 triage keeps getting it.
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"start the task"}}' \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_trivial_session(){ # $1=root $2=name — single user turn, no tool calls: below the noise gate
  local f="$1/projects/proj-a/$2.jsonl"
  printf '{"type":"user","message":{"content":"quick question"}}\n' > "$f"
  touch -t "$STAMP" "$f"
}
mk_short_duration_session(){ # $1=root $2=name — 2 user turns, 5s apart: gates on duration alone
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","timestamp":"2026-07-20T10:00:00Z","message":{"content":"quick check"}}' \
    '{"type":"user","timestamp":"2026-07-20T10:00:05Z","message":{"content":"thanks bye"}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_subagent_session(){ # $1=root $2=name — isSidechain + >=5 tool calls: carve-out, never gated
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","isSidechain":true,"timestamp":"2026-07-20T10:00:00Z","message":{"content":"subagent task"}}' \
    '{"type":"assistant","isSidechain":true,"timestamp":"2026-07-20T10:00:05Z","message":{"content":[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Write"},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Grep"},{"type":"tool_use","name":"Edit"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_timed_session(){ # $1=root $2=name $3.. = ISO8601 timestamps, one user turn each (#14 overlap fixtures)
  local root="$1" name="$2"; shift 2
  local f="$root/projects/proj-a/$name.jsonl" ts
  : > "$f"
  for ts in "$@"; do
    printf '{"type":"user","timestamp":"%s","message":{"content":"turn"}}\n' "$ts" >> "$f"
  done
  touch -t "$STAMP" "$f"
}
hash_of(){ printf '%s' "$1" | shasum -a 1 | cut -c1-12; }
run_dream(){ # $1=root ; inherits MOCK_MODE/MOCK_CAPTURE_DIR/FANOUT + changelog knobs from env
  # Changelog check defaults OFF so the suite never touches the network; the dedicated
  # changelog test exports AUTODREAM_CHANGELOG=1 with a local CHANGELOG_REMOTE.
  # Retry/network knobs forced fast+offline so the suite never sleeps or hits the net.
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG="${AUTODREAM_CHANGELOG:-0}" CLAUDE_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS="${AUTODREAM_L1_ROUNDS:-2}" \
  PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  bash "$RUN" "$DATE" > "$1/run.out" 2>&1
}
fdir(){ printf '%s' "$1/autodream/findings/$DATE"; }   # findings dir for a root

# ---------------------------------------------------------------------------

test_session_stats(){
  echo "# deterministic session stats pre-pass acceptance fixtures"
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local fixture out

  fixture="$root/carriers.jsonl"; out="$root/carriers.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"human question"}}' \
    '{"type":"assistant","message":{"model":"claude-haiku","content":[{"type":"tool_use","name":"Read"}]}}' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"result"}]}}' \
    'not json' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"result"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r 'keys | sort | join(",")' "$out")" \
    "compliance_markers,duration_minutes,isSidechain,models_used,tool_call_count,tools_used,transcript_bytes,transcript_mtime,turn_count,user_message_count,user_turn_timestamps" \
    "stats output has exactly the specified fields"
  assert_eq "$(jq -r '.user_turn_timestamps | length' "$out")" "0" "no timestamped user turns in this fixture -> empty user_turn_timestamps"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "tool_result carriers are excluded from user message count"
  assert_eq "$(jq -r .turn_count "$out")" "4" "turn count includes tool_result carriers"

  fixture="$root/timestamps.jsonl"; out="$root/timestamps.stats.json"
  printf '%s\n' \
    '{"type":"user","timestamp":"2026-07-20T10:00:00.500Z","message":{"content":"start"}}' \
    '{"type":"system","message":{"content":"no timestamp needed"}}' \
    '{"type":"assistant","message":{"model":"claude-opus","content":"middle"}}' \
    '{"type":"progress","timestamp":"2026-07-20T10:01:00.250Z"}' \
    '{"type":"assistant","timestamp":"2026-07-20T10:02:30.750Z","message":{"model":"<synthetic>","content":"end"}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .duration_minutes "$out")" "2.5" "duration uses available fractional timestamps"
  assert_eq "$(jq -r .models_used[0] "$out")" "claude-opus" "synthetic model is dropped"
  assert_eq "$(jq -r '.user_turn_timestamps | join(",")' "$out")" "1784541600" "user_turn_timestamps holds only the (fractional-second-truncated) real user turn's epoch"

  fixture="$root/markers.jsonl"; out="$root/markers.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"content":"user pasted RETRY-BUDGET: not a marker"}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"payload RETRY-BUDGET: not a marker"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"RETRY-BUDGET: real"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DELEGATED: scout — find X\nthe report said DELEGATED: quoted mid-line\n```\nDELEGATED: fenced example\nDIRECT-OK: fenced example\n```\nDIRECT-OK: tiny-edit — one-line fix"}]}}' \
    '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"DELEGATED: harvester — sidechain worker line"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r '.compliance_markers["RETRY-BUDGET"]' "$out")" "1" "only assistant text counts RETRY-BUDGET"
  assert_eq "$(jq -r '.compliance_markers["DELEGATED"]' "$out")" "1" "DELEGATED counts line-start only (mid-line, fenced, sidechain excluded)"
  assert_eq "$(jq -r '.compliance_markers["DIRECT-OK"]' "$out")" "1" "DIRECT-OK counts line-start only (fenced excluded)"
  assert_eq "$(jq -r '.compliance_markers | keys | sort | join(",")' "$out")" \
    "DELEGATED,DIRECT-OK,FETCH-PIVOT,RETRY-BUDGET" "compliance_markers carries all four keys"

  fixture="$root/text-image.jsonl"; out="$root/text-image.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"content":[{"type":"text","text":"caption"},{"type":"image","source":{"type":"base64","data":"abc"}}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "text plus image human turn counts"

  fixture="$root/sidechain.jsonl"; out="$root/sidechain.stats.json"
  printf '%s\n' \
    '{"type":"user","isSidechain":true,"message":{"content":"subagent task"}}' \
    '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku","content":[{"type":"tool_use","name":"Write"},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Read"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"one"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"two"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"three"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "sidechain has one human message"
  assert_eq "$(jq -r .turn_count "$out")" "5" "sidechain turn count includes carriers"
  assert_eq "$(jq -r .tool_call_count "$out")" "3" "sidechain tool calls are counted mechanically"
  assert_eq "$(jq -r '.tools_used | join(",")' "$out")" "Bash,Read,Write" "sidechain tools are sorted and unique"
  assert_eq "$(jq -r .isSidechain "$out")" "true" "sidechain marker is copied"
  rm -rf "$root"
}

test_happy(){
  echo "# happy path"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "L1 wrote findings JSON"
  assert_file    "$(fdir "$root")/$h.stats.json" "mechanical stats sidecar written"
  assert_eq      "$(jq -r .tool_call_count "$(fdir "$root")/$h.stats.json")" "1" "sidecar has plausible tool_call_count"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err on success"
  assert_file    "$root/dreams/$DATE.md"       "L2 wrote the report"
  rm -rf "$root"
}

test_unreadable(){
  echo "# unreadable session (validated before dispatch)"
  local root; root=$(setup_env); mk_session "$root" sess1
  chmod 000 "$root/projects/proj-a/sess1.jsonl"
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "unreadable -> structured error JSON written"
  assert_grep    "$(fdir "$root")/$h.json"     'not readable at dispatch' "error JSON states the reason"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err (structured record instead of a loop)"
  chmod 644 "$root/projects/proj-a/sess1.jsonl"; rm -rf "$root"
}

test_incomplete(){
  echo "# incomplete worker run (no JSON written)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # After the 2026-06-11 self-audit fix: on the FINAL retry round, a worker
  # that produced no output gets a metadata-only stub so the session is
  # visible to L1_ERRORED and the L2 aggregator instead of becoming a silent
  # .err. Earlier rounds still left the slot absent so retries could fire.
  assert_file     "$(fdir "$root")/$h.json"     "final-round stub written (no longer a silent failure)"
  assert_grep     "$(fdir "$root")/$h.json"     'worker exited without findings JSON' "stub carries the failure reason"
  # Whitespace-tolerant: the project-field normalization pass rewrites this stub via
  # json.dump (it has a real session_path + no project), reformatting "findings":[] →
  # "findings": []. The assertion is about the empty array, not its exact spacing.
  assert_grep     "$(fdir "$root")/$h.json"     '"findings": *\[\]'                   "stub has an empty findings array (counted by L1_ERRORED via the error key)"
  assert_nonempty "$(fdir "$root")/$h.json.err" ".err is still non-empty (per-round diagnostics)"
  assert_grep     "$(fdir "$root")/$h.json.err" 'incomplete run' ".err carries a diagnostic"
  assert_file     "$root/dreams/$DATE.md"       "L2 still produced the report"
  rm -rf "$root"
}

test_self_audit_stats(){
  echo "# run-stats.txt self-audit telemetry is written"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/x/y.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  assert_grep  "$stats" 'self_sessions_excluded: 1' "stats record the excluded self-session"
  assert_grep  "$stats" 'sessions_triaged: 1'        "stats record the triaged count"
  assert_grep  "$stats" 'l1_findings_with_error: 0'  "stats record the in-band error count"
  # 2026-06-11 self-audit fix: vs.-raw denominator + cache-disambiguating fields.
  assert_grep  "$stats" 'sessions_dropped_after_failures: 0'   "no dropped sessions on a clean happy-path run"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 0' "no precached findings on a fresh run"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 1'     "the one session was freshly processed this run"
  rm -rf "$root"
}

test_self_audit_stats_failure_denominator(){
  echo "# self-audit stats: dropped-after-failures is nonzero when a worker dies"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  # After the fix, even a stubbed final-round failure is counted: the stub
  # carries an "error" key so it lands in l1_findings_with_error, AND the
  # vs.-raw denominator stays accurate. Old behavior reported zero across
  # the board even though the session never produced real findings.
  assert_grep  "$stats" 'l1_findings_with_error: 1' "stats now surface the failed session via the error key"
  rm -rf "$root"
}

test_self_audit_stats_precached_disambiguation(){
  echo "# self-audit stats: precached findings counted so fast elapsed isn't 'impossible'"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Pre-seed a valid findings JSON so dispatcher's idempotency skips the worker.
  mkdir -p "$(fdir "$root")"; printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 1' "precached session counted as already done"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 0'     "no fresh work this run"
  rm -rf "$root"
}

test_idempotent(){
  echo "# idempotent (pre-existing VALID findings JSON is not re-run)"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # A valid findings record (has a top-level findings key) marks a completed
  # triage; the run must leave it untouched. Sentinel lives in session_path.
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"SENTINEL","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -r .session_path "$(fdir "$root")/$h.json")" "SENTINEL" "valid findings JSON left untouched"
  rm -rf "$root"
}

test_revalidates_garbage(){
  echo "# a non-empty but malformed findings JSON is re-dispatched, not counted as done"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Old contract treated any non-empty file as done; new contract re-runs a
  # record that lacks a valid top-level findings key (a worker that emitted
  # garbage). The mock worker overwrites it with a well-formed record.
  mkdir -p "$(fdir "$root")"; printf 'GARBAGE{not json' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -e 'has("findings")' "$(fdir "$root")/$h.json" 2>/dev/null)" "true" "garbage findings JSON re-dispatched and replaced"
  rm -rf "$root"
}

test_no_sessions(){
  echo "# no sessions for the date"
  local root; root=$(setup_env)   # no mk_session
  run_dream "$root"
  assert_file "$root/dreams/$DATE.md" "stub report written"
  assert_grep "$root/dreams/$DATE.md" 'No Claude Code sessions' "stub report has the no-sessions notice"
  rm -rf "$root"
}

test_framing(){
  echo "# prompt framing regression (literal paths, no \$VAR, blank separator)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset FANOUT MOCK_CAPTURE_DIR
  local cap="$root/cap/l1-stdin.txt"
  assert_file "$cap" "captured the L1 prompt"
  local l1 l2 l3 l4
  l1=$(sed -n '1p' "$cap"); l2=$(sed -n '2p' "$cap"); l3=$(sed -n '3p' "$cap"); l4=$(sed -n '4p' "$cap")
  case "$l1" in "Session transcript to analyze (literal absolute path): /"*) ok "line 1 = literal session path" ;; *) no "line 1 framing (got [$l1])" ;; esac
  case "$l2" in "Write your findings JSON to this literal absolute path: /"*) ok "line 2 = literal output path" ;; *) no "line 2 framing (got [$l2])" ;; esac
  assert_eq "$l3" "" "line 3 = blank separator (doc not glued onto the path)"
  case "$l4" in "# Session Triage"*) ok "line 4 = SESSION_TRIAGE.md begins" ;; *) no "line 4 doc start (got [$l4])" ;; esac
  local doc_line stats_line
  doc_line=$(grep -n '^## Output schema' "$cap" | head -n 1 | cut -d: -f1)
  stats_line=$(grep -n '^## Precomputed session stats' "$cap" | head -n 1 | cut -d: -f1)
  [ -n "$doc_line" ] && [ -n "$stats_line" ] && [ "$stats_line" -gt "$doc_line" ] \
    && ok "precomputed stats block follows the full SESSION_TRIAGE.md body" \
    || no "precomputed stats block follows the full SESSION_TRIAGE.md body"
  assert_grep "$cap" '"tool_call_count": 1' "captured L1 prompt contains the sidecar JSON"
  if printf '%s\n%s\n' "$l1" "$l2" | grep -qE 'SESSION_PATH=|OUTPUT_PATH=|[$]SESSION_PATH|[$]OUTPUT_PATH'; then
    no "no legacy KEY=value / \$VAR framing in the inlined header"
  else
    ok "no legacy KEY=value / \$VAR framing in the inlined header"
  fi
  assert_grep "$root/cap/l1-args.txt" 'not shell variables' "system prompt forbids shell-variable treatment"
  rm -rf "$root"
}

test_changelog(){
  echo "# upstream changelog window (offline, local fixture remote)"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1

  # Build a local 'remote' for anthropics/claude-code: one CHANGELOG commit dated
  # inside the target day [2020-01-02, 2020-01-03), one dated a month later (out of window).
  local up="$root/upstream"; mkdir -p "$up"
  ( cd "$up" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'release 2.1.999'
    printf '# Changelog\n\n## 2.2.0\n\n- Out-of-window mock feature\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-02-01T12:00:00" GIT_COMMITTER_DATE="2020-02-01T12:00:00" \
      git commit -q -m 'release 2.2.0' )

  export AUTODREAM_CHANGELOG=1 CHANGELOG_REMOTE="$up" CLAUDE_CODE_REPO="$root/cache/cc"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG CHANGELOG_REMOTE CLAUDE_CODE_REPO

  local cw="$(fdir "$root")/changelog-window.md"
  assert_file   "$cw" "changelog-window.md written"
  assert_grep   "$cw" '2.1.999'              "captures the in-window release"
  assert_grep   "$cw" 'In-window mock'       "captures the in-window bullet"
  assert_nogrep "$cw" '2.2.0'                "excludes the out-of-window release"
  rm -rf "$root"
}

test_prune_helper(){
  echo "# prune-self-sessions helper: list / filter / delete"
  local PR="$REPO/bin/prune-self-sessions.sh"
  [ -x "$PR" ] || { no "prune helper executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/-Users-x"
  local self="$root/projects/-Users-x/self.jsonl" real="$root/projects/-Users-x/real.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"Session transcript to analyze (literal absolute path): /x"}}\n' > "$self"
  printf '{"type":"user","message":{"role":"user","content":"fix the bug in foo.ts"}}\n' > "$real"

  local out; out=$(PROJECTS_DIR="$root/projects" "$PR")
  case "$out" in *self.jsonl*) ok "list includes the self session" ;; *) no "list includes the self session (got [$out])" ;; esac
  case "$out" in *real.jsonl*) no "list must exclude the real session" ;; *) ok "list excludes the real session" ;; esac

  printf '%s\n%s\n' "$self" "$real" | "$PR" --filter > "$root/filtered.txt"
  assert_grep   "$root/filtered.txt" 'real.jsonl' "filter keeps the real session"
  assert_nogrep "$root/filtered.txt" 'self.jsonl' "filter drops the self session"

  PROJECTS_DIR="$root/projects" "$PR" --delete >/dev/null
  assert_no_file "$self" "self session deleted"
  assert_file    "$real" "real session kept"
  rm -rf "$root"
}

test_self_session_excluded(){
  echo "# autodream's own transcripts are excluded from triage"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/Users/x/.claude/projects/foo/bar.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local hr hs; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); hs=$(hash_of "$sf")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$hs.json" "self-session excluded (no findings JSON)"
  assert_grep    "$root/run.out" 'excluded 1 autodream-own' "run log reports the exclusion"
  rm -rf "$root"
}

test_skip_empty_sessions(){
  echo "# 0-turn shell sessions are skipped before fanout"
  local root; root=$(setup_env); mk_session "$root" real1
  # an auto-opened/aborted shell: a single ai-title line, no user turn at all
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  run_dream "$root"
  local hr he; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); he=$(hash_of "$empty")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$he.json" "empty shell skipped (no findings JSON)"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 1' "stats record the empty skip"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "stats record one triaged"
  assert_grep    "$root/run.out" 'skipped 1 empty' "run log reports the empty skip"
  rm -rf "$root"
}

test_skip_empty_disabled(){
  echo "# AUTODREAM_SKIP_EMPTY=0 keeps 0-turn shells in the triage set"
  local root; root=$(setup_env)
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  export AUTODREAM_SKIP_EMPTY=0; run_dream "$root"; unset AUTODREAM_SKIP_EMPTY
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 0' "no skips when disabled"
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "shell still triaged when disabled"
  rm -rf "$root"
}

test_l1_retry(){
  echo "# L1 retries a flaky session and completes it on a later round"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_flaky AUTODREAM_L1_ROUNDS=3; run_dream "$root"; unset MOCK_MODE AUTODREAM_L1_ROUNDS
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file "$(fdir "$root")/$h.json"  "flaky session produced findings on retry"
  assert_grep "$root/run.out" 'round 2'  "a second L1 round ran"
  assert_file "$root/dreams/$DATE.md"    "report still produced"
  rm -rf "$root"
}

test_idempotency_guard(){
  echo "# existing report short-circuits the run (launchd catch-up no-op)"
  local root; root=$(setup_env); mk_session "$root" sess1
  printf 'SENTINEL REPORT' > "$root/dreams/$DATE.md"
  run_dream "$root"
  assert_eq   "$(cat "$root/dreams/$DATE.md")" "SENTINEL REPORT" "existing report left untouched"
  assert_grep "$root/run.out" 'already exists' "run logged the skip"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_no_file "$(fdir "$root")/$h.json" "no L1 work done when report already exists"
  rm -rf "$root"
}

test_normalize_project(){
  echo "# project field is normalized deterministically from the session path"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_badproject; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  local fj="$(fdir "$root")/$h.json"
  assert_file   "$fj" "findings JSON written"
  assert_nogrep "$fj" 'WRONG-PROJECT'     "model's wrong project value was overwritten"
  assert_grep   "$fj" '"project": "proj-a"' "project normalized to the session dir basename"
  assert_grep   "$root/run.out" 'normalized project field' "run log reports normalization"
  # l1_badproject emits the pre-pilot JSON shape (no facet fields) — the report
  # landing proves L2 still accepts legacy findings.
  assert_file   "$root/dreams/$DATE.md" "L2 completed on facet-free legacy findings"
  rm -rf "$root"
}

test_slim_transcript(){
  echo "# slim-transcript bounds an oversized transcript"
  local SL="$REPO/bin/slim-transcript.sh"
  [ -x "$SL" ] || { no "slim-transcript executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local big="$root/big.jsonl" out="$root/slim.jsonl"
  # 3000 lines × ~3000 chars ≈ 9 MB
  awk 'BEGIN{ b=""; for(i=0;i<3000;i++) b=b "x"; for(n=0;n<3000;n++) print "{\"n\":" n ",\"blob\":\"" b "\"}" }' > "$big"
  "$SL" "$big" "$out"
  local osz; osz=$(wc -c < "$out" | tr -d ' ')
  [ "$osz" -lt 300000 ] && ok "slimmed far below original ($osz bytes < 300k, orig ~9M)" || no "slim output too big ($osz)"
  assert_grep "$out" 'elided by autodream'     "elides the middle"
  assert_grep "$out" 'slimmed this transcript' "appends the slim note"
  rm -rf "$root"
}

test_facet_fields_plumbed(){
  echo "# pilot facet fields flow L1 -> findings JSON -> L2 input"
  # Plumbing only: the L2 mock ignores findings content, so assertions stop at
  # the findings JSON L2 reads. Behavioral quality is the production pilot's job.
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h j; h=$(hash_of "$root/projects/proj-a/sess1.jsonl"); j="$(fdir "$root")/$h.json"
  assert_eq "$(jq -r .outcome "$j")"                          "fully_achieved" "outcome facet present in findings JSON"
  assert_eq "$(jq -r .satisfaction_signals.satisfied "$j")"   "1"              "satisfaction_signals present"
  assert_eq "$(jq -e 'has("underlying_goal")' "$j")"          "true"           "underlying_goal key present (null allowed)"
  assert_eq "$(jq -r '.instructions_given[0]' "$j")"          "always run tests after edits" "instructions_given present"
  assert_file "$root/dreams/$DATE.md" "L2 run completed with facet-bearing findings as input"
  rm -rf "$root"
}

test_noise_gate_trivial(){
  echo "# noise gate: a trivial (1-user-turn) session is stubbed, not sent to the model"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  export MOCK_CALL_LOG="$root/calls.log"
  run_dream "$root"
  unset MOCK_CALL_LOG
  local hr ht
  hr=$(hash_of "$root/projects/proj-a/real1.jsonl")
  ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_file    "$(fdir "$root")/$ht.json"     "gated session still got a findings JSON (the stub)"
  # Whitespace-tolerant like test_incomplete: the project-field normalization
  # pass rewrites this stub via json.dump (it has a real session_path + no
  # project), reformatting "skipped":"below_noise_gate" -> "skipped": "..." etc.
  assert_grep    "$(fdir "$root")/$ht.json"     '"skipped": *"below_noise_gate"' "gated stub carries the skip reason"
  assert_grep    "$(fdir "$root")/$ht.json"     '"findings": *\[\]'              "gated stub has an empty findings array"
  assert_no_file "$(fdir "$root")/$ht.json.err" "no .err for a gated session (clean skip, not a failure)"
  assert_grep    "$root/calls.log" "$hr" "model was called for the real session"
  assert_nogrep  "$root/calls.log" "$ht" "model was NOT called for the gated session"
  rm -rf "$root"
}

test_noise_gate_short_duration(){
  echo "# noise gate: duration alone gates even with enough user turns"
  local root; root=$(setup_env)
  mk_short_duration_session "$root" short1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/short1.jsonl")
  assert_grep "$(fdir "$root")/$h.json" '"skipped": *"below_noise_gate"' "short-duration session gated despite 2 user turns"
  rm -rf "$root"
}

test_noise_gate_subagent_carveout(){
  echo "# noise gate: subagent / high-tool-count sessions are never gated"
  local root; root=$(setup_env)
  mk_subagent_session "$root" subagent1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/subagent1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "subagent session was not gated"
  assert_grep   "$(fdir "$root")/$h.json" 'fully_achieved'    "subagent session got real findings from the model"
  rm -rf "$root"
}

test_noise_gate_stats(){
  echo "# noise gate: gated count in run-stats.txt; precache count stays truthful alongside gating"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  mk_session "$root" cached1
  local hc; hc=$(hash_of "$root/projects/proj-a/cached1.jsonl")
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$hc.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'gated: 1'                        "gated count recorded"
  assert_grep "$stats" 'sessions_triaged: 3'              "all three sessions counted as triaged"
  assert_grep "$stats" 'l1_sessions_already_done_at_start: 1' "precache count unaffected by gating (only cached1 was precached)"
  local ht; ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_grep "$(fdir "$root")/$ht.json" 'below_noise_gate' "gated session got the stub"
  rm -rf "$root"
}

test_noise_gate_env_override(){
  echo "# noise gate: AUTODREAM_MIN_USER_TURNS override changes the threshold"
  local root; root=$(setup_env)
  mk_trivial_session "$root" trivial1
  export AUTODREAM_MIN_USER_TURNS=1
  run_dream "$root"
  unset AUTODREAM_MIN_USER_TURNS
  local h; h=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "lowering the threshold keeps the 1-turn session out of the gate"
  rm -rf "$root"
}

test_oversized_gate_zero(){
  echo "# oversized gate (#12 measurement): both keys present at 0 on a normal run"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 0'   "no oversized sessions under the default threshold"
  assert_grep "$stats" 'oversized_errored: 0' "no oversized-errored sessions under the default threshold"
  rm -rf "$root"
}

test_oversized_gate_total(){
  echo "# oversized gate (#12 measurement): a session over a lowered AUTODREAM_SLIM_BYTES counts as oversized"
  local root; root=$(setup_env); mk_session "$root" sess1
  # mk_session's fixture is 205 bytes; a threshold of 100 puts it over the line
  # without needing a multi-KB fixture. slim-transcript.sh also fires at this
  # size (harmless — the mock still writes findings regardless of readpath).
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "one session counted as oversized"
  assert_grep "$stats" 'oversized_errored: 0' "the oversized session still triaged cleanly (no error key)"
  rm -rf "$root"
}

test_oversized_gate_errored(){
  echo "# oversized gate (#12 measurement): an oversized session that still errors is paired correctly"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Force the final-round metadata stub (carries a top-level "error" key) on an
  # oversized session, and verify oversized_errored pairs the right hash's
  # stats sidecar to the right findings JSON (not just a raw count).
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_incomplete AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "the incomplete session still counted as oversized"
  assert_grep "$stats" 'oversized_errored: 1' "its final-round error stub is paired and counted"
  rm -rf "$root"
}

test_stats_sidecar_ok(){
  echo "# sidecar health (#27): a normal run reports zero unparseable sidecars"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 0' "healthy sidecars report a real zero"
  rm -rf "$root"
}

test_stats_sidecar_missing_counted(){
  echo "# sidecar health (#27): a session-stats.sh that never runs is counted, not silently absorbed"
  local root; root=$(setup_env)
  mk_session "$root" sess1
  mk_session "$root" sess2
  # compute_session_stats deletes and regenerates every sidecar each run, so the
  # only way to force the broken-sidecar path is to break the generator itself.
  export AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 2' "both missing sidecars counted"
  rm -rf "$root"
}

test_stats_sidecar_missing_keeps_oversized_count(){
  echo "# sidecar health (#27): an oversized session does NOT vanish from oversized_total when its sidecar is missing"
  local root; root=$(setup_env); mk_session "$root" sess1
  # This is the issue's exact reproduction: a genuinely oversized session whose
  # sidecar never got written used to drop straight out of oversized_total, the
  # counter that gates #12, with nothing recording that it happened.
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "and the sidecar failure is recorded alongside it"
  rm -rf "$root"
}

test_stats_sidecar_malformed_counted(){
  echo "# sidecar health (#27): a sidecar that is a valid object but has no usable transcript_bytes is counted"
  local root; root=$(setup_env); mk_session "$root" sess1
  # compute_session_stats only validates `type == "object"`, so this stub survives
  # generation intact and breaks at read time instead — the quieter of the two paths.
  local stub="$root/stats-no-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"user_message_count\":5,\"tool_call_count\":9}" > "$2"' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$stub"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "missing transcript_bytes counts as unparseable"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  rm -rf "$root"
}

test_stats_sidecar_non_numeric_counted(){
  echo "# sidecar health (#27): a non-numeric transcript_bytes is counted, not clamped to 0 in silence"
  local root; root=$(setup_env); mk_session "$root" sess1
  local stub="$root/stats-bad-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"transcript_bytes\":\"lots\"}" > "$2"' > "$stub"
  export AUTODREAM_STATS_BIN="$stub"
  chmod +x "$stub"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "a string transcript_bytes is not a measurement"
  rm -rf "$root"
}

test_overlap_pair(){
  echo "# overlap (#14): two alternating-close sessions count as ONE pair regardless of qualifying turn-pairs"
  local root; root=$(setup_env)
  # A: 10:00, 10:20   B: 10:05, 10:25 — every A/B turn combo is within 30 min
  # (A0-B0=5m, A0-B1=25m, A1-B0=15m, A1-B1=5m), so four turn-pairs qualify but
  # the {A,B} pair must be counted exactly once.
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z" "2026-07-20T10:20:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z" "2026-07-20T10:25:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 1'         "exactly one distinct pair counted"
  assert_grep "$stats" 'sessions_with_overlap: 2'  "both sessions counted as involved"
  rm -rf "$root"
}

test_overlap_triple(){
  echo "# overlap (#14): three pairwise-overlapping sessions -> 3 pairs, 3 sessions"
  local root; root=$(setup_env)
  # A@10:00, B@10:10, C@10:20 — every pair (A-B=10m, B-C=10m, A-C=20m) is within 30 min.
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:10:00Z"
  mk_timed_session "$root" sessC "2026-07-20T10:20:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 3'         "all three pairs counted"
  assert_grep "$stats" 'sessions_with_overlap: 3'  "all three sessions counted as involved"
  rm -rf "$root"
}

test_overlap_none(){
  echo "# overlap (#14): sessions more than 30 minutes apart -> both stats 0, keys still present"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T11:00:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  # This is the genuine-zero case (#26): the pass DID run, it just found nothing to
  # pair. overlap_measured must positively say so — that's the whole point of the fix,
  # distinguishing this from a pass that never ran.
  assert_grep "$stats" 'overlap_measured: yes'     "genuine zero overlap is still a real measurement"
  assert_grep "$stats" 'overlap_events: 0'         "no pairs when sessions are far apart"
  assert_grep "$stats" 'sessions_with_overlap: 0'  "no sessions involved when sessions are far apart"
  rm -rf "$root"
}

test_overlap_not_measured_missing_bin(){
  echo "# overlap (#26): AUTODREAM_OVERLAP_BIN pointed at a nonexistent path -> not measured, counts still 0"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  export AUTODREAM_OVERLAP_BIN="$root/does-not-exist.sh"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "missing overlap-stats.sh binary is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_empty_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints nothing -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  local stub="$root/overlap-empty.sh"
  printf '#!/bin/bash\nexit 0\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "empty overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_malformed_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints non-JSON -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  local stub="$root/overlap-malformed.sh"
  printf '#!/bin/bash\necho "not json at all"\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "malformed overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

# ---------------------------------------------------------------------------

[ -x "$RUN" ]  || { echo "FATAL: $RUN not executable"; exit 1; }
[ -x "$MOCK" ] || { echo "FATAL: $MOCK not executable"; exit 1; }

echo "cc-autodream integration tests (mock claude)"
echo
test_happy
test_session_stats
test_unreadable
test_incomplete
test_idempotent
test_revalidates_garbage
test_no_sessions
test_framing
test_changelog
test_prune_helper
test_self_session_excluded
test_skip_empty_sessions
test_skip_empty_disabled
test_l1_retry
test_idempotency_guard
test_self_audit_stats
test_self_audit_stats_failure_denominator
test_self_audit_stats_precached_disambiguation
test_normalize_project
test_slim_transcript
test_facet_fields_plumbed
test_noise_gate_trivial
test_noise_gate_short_duration
test_noise_gate_subagent_carveout
test_noise_gate_stats
test_noise_gate_env_override
test_oversized_gate_zero
test_oversized_gate_total
test_oversized_gate_errored
test_stats_sidecar_ok
test_stats_sidecar_missing_counted
test_stats_sidecar_missing_keeps_oversized_count
test_stats_sidecar_malformed_counted
test_stats_sidecar_non_numeric_counted
test_overlap_pair
test_overlap_triple
test_overlap_none
test_overlap_not_measured_missing_bin
test_overlap_not_measured_empty_output
test_overlap_not_measured_malformed_output
echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
