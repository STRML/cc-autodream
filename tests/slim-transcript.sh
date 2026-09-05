#!/bin/bash
# Unit tests for bin/slim-transcript.sh's jq pre-pass.
#
# The pre-pass handles two transcript schemas that store tool output in
# completely different places, and it fails SILENTLY when it gets one wrong: jq
# exits 0 and writes a valid file, so the shell fallback never fires and the
# line-based pass downstream happily truncates an OMP envelope at '"content":['.
# The worker then receives ID soup and returns no findings, which looks exactly
# like a quiet day.
#
# So these assertions are about what SURVIVES the strip, not about whether the
# script exits 0. Every one of them passed a smoke test before it was written.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SLIM="$REPO/bin/slim-transcript.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (got: [$2])" ;; esac; }
hasnt(){ case "$2" in *"$1"*) no "$3 (found [$1] in: [$2])" ;; *) ok "$3" ;; esac; }

[ -x "$SLIM" ] || {
  printf '  FAIL - bin/slim-transcript.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; the pre-pass is skipped and so is this suite\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/slimtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Run the slimmer over one JSONL record and print the result. head/tail/cap are
# raised well clear so ONLY the jq pre-pass is under test; the line-based pass is
# a separate mechanism and would otherwise mask what the pre-pass did.
slim_one() { # $1=json record -> slimmed record on stdout
  printf '%s\n' "$1" > "$TMP/in.jsonl"
  AUTODREAM_SLIM_MAXLINE=100000 AUTODREAM_SLIM_HEAD=9000 AUTODREAM_SLIM_TAIL=9000 \
  AUTODREAM_SLIM_CAP=100000000 \
    "$SLIM" "$TMP/in.jsonl" "$TMP/out.txt" >/dev/null 2>&1
  grep -m1 '^{' "$TMP/out.txt" 2>/dev/null
}

echo "# slim: a null or absent value is not turned into the string \"null\""
# The bug this suite was written for. `trunc` ran `tostring` unconditionally, so
# a toolResult carrying no content came out asserting the literal text "null" —
# a value the worker reads as real tool output.
got=$(slim_one '{"message":{"role":"toolResult","content":null,"toolName":"Read"}}')
hasnt '"null"' "$got" "a null .content does not become the string \"null\""
has '"toolName":"Read"' "$got" "and the rest of the record survives"

got=$(slim_one '{"message":{"role":"toolResult","toolName":"Read"}}')
hasnt '"content"' "$got" "an ABSENT .content is not invented as a key"

echo "# slim: a small structured value keeps its structure"
# tostring flattened `arguments` to an escaped JSON string even 40x under the
# cap, so triage lost the field names it reads. Structure is the payload here.
got=$(slim_one '{"message":{"content":[{"type":"toolCall","arguments":{"file":"a.txt","n":3}}]}}')
has '"file":"a.txt"' "$got" "short arguments stay an object, not an escaped string"
hasnt '\\"file\\"' "$got" "and are not stringified"

echo "# slim: an oversized value IS truncated"
# The cap has to still work, or the fix above traded one silent failure for a
# different one. 700 chars against a 600-char cap.
big=$(printf 'x%.0s' $(seq 1 700))
got=$(slim_one "{\"message\":{\"role\":\"toolResult\",\"content\":\"$big\"}}")
has 'autodream: truncated' "$got" "a 700-char content is truncated at the 600 cap"
[ "${#got}" -lt 900 ] && ok "and the record shrank" || no "and the record shrank (len ${#got})"

echo "# slim: Claude Code tool_result blocks are stripped, provenance kept"
got=$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":[{"type":"text","text":"HUGE"}]}]}}')
has 'payload stripped' "$got" "the payload goes"
has '"tool_use_id":"tu_1"' "$got" "tool_use_id is kept so triage can name the call"
has '"is_error":true' "$got" "is_error is kept so triage can tell a failure"

echo "# slim: OMP toolResult details are stripped"
got=$(slim_one '{"message":{"role":"toolResult","details":{"big":"payload"},"content":"short"}}')
has 'details stripped' "$got" "OMP .details is stripped"
has '"content":"short"' "$got" "a short OMP content survives intact"

echo "# slim: providerPayload never survives"
got=$(slim_one '{"message":{"role":"assistant","providerPayload":{"raw":"secretish"},"content":"hi"}}')
hasnt 'providerPayload' "$got" "the raw provider round-trip is dropped"
hasnt 'secretish' "$got" "and its contents go with it"

echo "# slim: a record the pre-pass does not understand passes through"
# The fallback is the whole reason this is safe to run on an unknown schema.
got=$(slim_one '{"type":"queue-operation","payload":{"a":1}}')
has 'queue-operation' "$got" "an unknown record shape is not dropped"

echo "# slim: non-JSONL input falls back instead of producing nothing"
printf 'this is not json\nnor is this\n' > "$TMP/plain.txt"
AUTODREAM_SLIM_MAXLINE=100000 "$SLIM" "$TMP/plain.txt" "$TMP/plain.out" >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" "a non-JSONL transcript still exits 0"
[ -s "$TMP/plain.out" ] && ok "and still writes output" || no "and still writes output"
has 'this is not json' "$(cat "$TMP/plain.out" 2>/dev/null)" "the original text survives the fallback"

echo "# slim: no .pre.jsonl temp is left behind"
ls "$TMP"/*.pre.jsonl >/dev/null 2>&1 && no "the pre-pass temp is cleaned up" \
  || ok "the pre-pass temp is cleaned up"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
