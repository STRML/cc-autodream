#!/bin/bash
# Apply Layer 2's memory pins to Mnemopi.
#
#   apply-pins.sh <findings-dir> <target-date>
#
# Reads two files from <findings-dir>:
#   pins.jsonl        one pin per line, written by L2:
#                     {"project","title","body","kind"}
#   pin-projects.tsv  project<TAB>cwd for every project this run triaged,
#                     written by run.sh. It is the authorization list: a pin
#                     naming any other project is refused.
#
# Each valid pin becomes one `shared-memory call mnemopi_remember`, scoped with
# --cwd to its project's working directory.
#
# Writes, inside <findings-dir>:
#   pins-applied.tsv  <sha1 of the canonical pin><TAB><memory_id> per stored
#                     pin. A pin already listed is skipped, so a rerun never
#                     stores the same memory twice. A failed call writes no row,
#                     so a later run retries it.
#   pins-result.txt   counters, one `key: value` per line.
#
# Exit 2 on bad arguments. Otherwise exit 0 whatever happened to the pins: a
# pin must never cost a report, and the counters say what went wrong.
#
# SHARED_MEMORY_BIN overrides the CLI (default: `shared-memory` on PATH). The
# test suite points it at a mock so no test writes real memory.
#
# Plan and failure matrix: docs/plans/2026-09-15-mnemopi-pins.md
set -u

if [ $# -ne 2 ] || [ ! -d "${1:-}" ]; then
  echo "usage: apply-pins.sh <findings-dir> <target-date>" >&2
  exit 2
fi

FINDINGS_DIR=$1
TARGET_DATE=$2
PINS="$FINDINGS_DIR/pins.jsonl"
PROJECTS="$FINDINGS_DIR/pin-projects.tsv"
LEDGER="$FINDINGS_DIR/pins-applied.tsv"
RESULT="$FINDINGS_DIR/pins-result.txt"
SM="${SHARED_MEMORY_BIN:-shared-memory}"

# A pin is valid when this filter prints it. Anything else, including a line
# holding two JSON values, prints nothing.
VALID='select(type == "object")
  | select((.project | type) == "string" and (.project | length) > 0
           and (.project | test("[\\t\\n\\r]") | not))
  | select((.title | type) == "string" and (.title | test("\\S"))
           and (.title | length) <= 150 and (.title | test("[\\n\\r]") | not))
  | select((.body | type) == "string" and (.body | test("\\S"))
           and (.body | length) <= 4000)
  | select(.kind as $k | ["correction", "preference", "fact", "decision"] | index($k))
  | {project, title, body, kind}'

total=0 applied=0 duplicate=0 invalid=0 rejected_project=0 no_cwd=0 failed=0 cli_missing=0

write_result() {
  {
    printf 'pins_total: %s\n' "$total"
    printf 'pins_applied: %s\n' "$applied"
    printf 'pins_duplicate: %s\n' "$duplicate"
    printf 'pins_invalid: %s\n' "$invalid"
    printf 'pins_rejected_project: %s\n' "$rejected_project"
    printf 'pins_no_cwd: %s\n' "$no_cwd"
    printf 'pins_failed: %s\n' "$failed"
    printf 'pins_cli_missing: %s\n' "$cli_missing"
  } > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
  echo "apply-pins: total=$total applied=$applied duplicate=$duplicate invalid=$invalid rejected_project=$rejected_project no_cwd=$no_cwd failed=$failed cli_missing=$cli_missing"
}

# $1=project -> prints its cwd column; exit 1 when the run never saw the project.
# ENVIRON, not awk -v: -v expands backslash escapes, so a model-written project
# could match a row it does not name.
project_cwd() {
  local row
  row=$(P="$1" awk -F'\t' '$1 == ENVIRON["P"] { print "y\t" $2; exit }' "$PROJECTS" 2>/dev/null)
  [ -n "$row" ] || return 1
  printf '%s' "${row#y$'\t'}"
}

# $1=line -> prints one outcome: invalid rejected_project no_cwd duplicate failed applied
apply_line() {
  local canon project cwd hash payload out id
  canon=$(jq -cS -s "if length == 1 then .[0] | $VALID else empty end" <<<"$1" 2>/dev/null)
  [ -n "$canon" ] || { echo invalid; return; }
  project=$(jq -r .project <<<"$canon")
  cwd=$(project_cwd "$project") || { echo rejected_project; return; }
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then echo no_cwd; return; fi
  hash=$(printf '%s' "$canon" | shasum -a 1 | cut -d' ' -f1)
  if [ -f "$LEDGER" ] && cut -f1 "$LEDGER" | grep -qxF "$hash"; then echo duplicate; return; fi
  payload=$(jq -cn --argjson pin "$canon" --arg date "$TARGET_DATE" '{
    bank: "default",
    content: ($pin.title + "\n\n" + $pin.body),
    source: "cc-autodream",
    importance: 0.7,
    metadata: {kind: $pin.kind, project: $pin.project, autodream_date: $date, origin: "cc-autodream"}
  }')
  # </dev/null: the caller reads pins.jsonl on a separate fd, but a CLI that
  # reads stdin must never be able to swallow the pins after this one.
  out=$("$SM" call mnemopi_remember "$payload" --cwd "$cwd" </dev/null) || { echo failed; return; }
  id=$(jq -er 'select(.status == "stored") | .memory_id | strings' <<<"$out" 2>/dev/null) || { echo failed; return; }
  printf '%s\t%s\n' "$hash" "$id" >> "$LEDGER"
  echo applied
}

if [ ! -f "$PINS" ]; then
  write_result
  exit 0
fi

if ! command -v "$SM" >/dev/null 2>&1; then
  cli_missing=1
  total=$(grep -c '[^[:space:]]' "$PINS" || true)
  write_result
  echo "apply-pins: $SM not found; pins stay in $PINS" >&2
  exit 0
fi

while IFS= read -r line <&3 || [ -n "$line" ]; do
  case $line in *[![:space:]]*) ;; *) continue ;; esac
  total=$((total + 1))
  case $(apply_line "$line") in
    applied)          applied=$((applied + 1)) ;;
    duplicate)        duplicate=$((duplicate + 1)) ;;
    invalid)          invalid=$((invalid + 1)) ;;
    rejected_project) rejected_project=$((rejected_project + 1)) ;;
    no_cwd)           no_cwd=$((no_cwd + 1)) ;;
    *)                failed=$((failed + 1)) ;;
  esac
done 3< "$PINS"

write_result
exit 0
