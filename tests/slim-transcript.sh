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
# An EMPTY haystack is a failure, not a pass. Every `hasnt` in this file was
# vacuous whenever the slimmer produced no output at all — the strongest possible
# regression, a slimmer that emits nothing, satisfied all of them. The guard lives
# in the helper because the defect is the helper's, not any one call site's.
# `has` and `jq_is` already fail on empty input by construction.
hasnt(){
  [ -n "$2" ] || { no "$3 (nothing to check: the slimmer produced no output)"; return; }
  case "$2" in *"$1"*) no "$3 (found [$1] in: [$2])" ;; *) ok "$3" ;; esac
}
# Type and presence claims go through jq, never through a substring match.
# The first version asserted `hasnt '\\"file\\"'` to mean "not stringified" —
# jq emits ONE backslash there, so the pattern could never match and the
# assertion passed whatever the code did. It survived the red-then-green check
# for the same reason. An assertion that cannot fail is decoration.
jq_is(){ # $1=slimmer output (may be several lines) $2=jq expr $3=want $4=msg
  local rec g rc
  rec=$(printf '%s\n' "$1" | grep -m1 '^{')
  # jq's exit status is checked. Ignoring it meant a record that produced the
  # expected value and THEN hit malformed bytes still passed.
  g=$(printf '%s' "$rec" | jq -r "$2" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { no "$4 (jq exit $rc on: [$rec])"; return; }
  assert_eq "$g" "$3" "$4"
}

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
slim_one() { # $1=json record -> slimmed record on stdout, or nothing on failure
  printf '%s\n' "$1" > "$TMP/in.jsonl"
  # Remove the destination FIRST and check the exit status. Without both, a
  # failed invocation left the previous case's output sitting at $TMP/out.txt
  # and the grep below returned THAT — so a broken slimmer would be asserted
  # against a stale record from an earlier assertion and pass.
  rm -f "$TMP/out.txt"
  AUTODREAM_SLIM_MAXLINE=100000 AUTODREAM_SLIM_HEAD=9000 AUTODREAM_SLIM_TAIL=9000 \
  AUTODREAM_SLIM_CAP=100000000 \
    "$SLIM" "$TMP/in.jsonl" "$TMP/out.txt" >/dev/null 2>&1 || return 1
  # The WHOLE output, not `grep -m1 '^{'`. Returning only the first record meant
  # every negative assertion inspected one line, so a slimmer emitting a clean
  # record followed by the original payload on line two passed them all. jq_is
  # picks the first record out for itself.
  cat "$TMP/out.txt" 2>/dev/null
}

echo "# slim: the script parses at all"
# Cheap, and it would have caught the bug that produced this line. The jq program
# is a single-quoted shell string, so ONE apostrophe anywhere inside it — in a
# comment, in the word "commit's" — terminates the quote and the whole file stops
# parsing. CLAUDE.md documents this trap for run.sh's L1 worker body; it applies
# to every single-quoted program in this repo.
if bash -n "$SLIM" 2>/dev/null; then ok "bin/slim-transcript.sh parses"
else no "bin/slim-transcript.sh has a shell syntax error (stray apostrophe in the jq program?)"; fi

echo "# slim: a null or absent value is not turned into the string \"null\""
# The bug this suite was written for. `trunc` ran `tostring` unconditionally, so
# a toolResult carrying no content came out asserting the literal text "null" —
# a value the worker reads as real tool output.
got=$(slim_one '{"message":{"role":"toolResult","content":null,"toolName":"Read"}}')
# BOTH assertions, because `type` alone reports "null" for an absent key too, so
# a regression that simply deleted .content would satisfy the type check.
jq_is "$got" '.message | has("content")' 'true' "an explicit null .content is KEPT, not deleted"
jq_is "$got" '.message.content | type' 'null' "and stays JSON null, not the string \"null\""
has '"toolName":"Read"' "$got" "and the rest of the record survives"

got=$(slim_one '{"message":{"role":"toolResult","toolName":"Read"}}')
jq_is "$got" '.message | has("content")' 'false' "an ABSENT .content is not invented as a key"
jq_is "$got" '.message.toolName' 'Read' "and the surrounding record is not simply dropped"

echo "# slim: a small structured value keeps its structure"
# tostring flattened `arguments` to an escaped JSON string even 40x under the
# cap, so triage lost the field names it reads. Structure is the payload here.
got=$(slim_one '{"message":{"content":[{"type":"toolCall","arguments":{"file":"a.txt","n":3}}]}}')
jq_is "$got" '.message.content[0].arguments | type' 'object' \
  "short arguments stay an OBJECT, not an escaped string"
jq_is "$got" '.message.content[0].arguments.file' 'a.txt' "and the field names triage reads survive"

# The false branch of the second has() guard. Without a fixture that OMITS
# arguments, a regression reintroducing a bare `.arguments = (...)` assignment
# would invent the key and every assertion above would still pass.
got=$(slim_one '{"message":{"content":[{"type":"toolCall","toolName":"Read"}]}}')
jq_is "$got" '.message.content[0] | has("arguments")' 'false' \
  "an ABSENT .arguments is not invented either"
jq_is "$got" '.message.content[0].type' 'toolCall' "and that block is not simply dropped"

echo "# slim: thinking blocks are capped without being fabricated"
got=$(slim_one '{"message":{"content":[{"type":"thinking","signature":"sig1"}]}}')
jq_is "$got" '.message.content[0] | has("thinking")' 'false' \
  "an ABSENT .thinking is not invented as an empty string"
jq_is "$got" '.message.content[0].signature' 'sig1' "and the block survives"
got=$(slim_one '{"message":{"content":[{"type":"thinking","thinking":null}]}}')
jq_is "$got" '.message.content[0].thinking | type' 'null' \
  "an explicit null .thinking stays null, not \"\""
bigt=$(printf 'y%.0s' $(seq 1 900))
got=$(slim_one "{\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"$bigt\"}]}}")
has 'autodream: truncated' "$got" "a 900-char thinking block is capped at 800"

echo "# slim: an oversized value IS truncated"
# The cap has to still work, or the fix above traded one silent failure for a
# different one. 700 chars against a 600-char cap.
big=$(printf 'x%.0s' $(seq 1 700))
got=$(slim_one "{\"message\":{\"role\":\"toolResult\",\"content\":\"$big\"}}")
has 'autodream: truncated' "$got" "a 700-char content is truncated at the 600 cap"
[ "${#got}" -lt 900 ] && ok "and the record shrank" || no "and the record shrank (len ${#got})"

echo "# slim: Claude Code tool_result blocks are stripped, provenance kept"
got=$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":[{"type":"text","text":"HUGE"}]}]}}')
has 'payload stripped' "$got" "the marker is inserted"
hasnt 'HUGE' "$got" "and the original payload is actually GONE, not just annotated"
has '"tool_use_id":"tu_1"' "$got" "tool_use_id is kept so triage can name the call"
has '"is_error":true' "$got" "is_error is kept so triage can tell a failure"

echo "# slim: OMP toolResult details are stripped"
got=$(slim_one '{"message":{"role":"toolResult","details":{"big":"payload"},"content":"short"}}')
has 'details stripped' "$got" "OMP .details gets the marker"
hasnt '"big":"payload"' "$got" "and the original details payload is actually gone"
has '"content":"short"' "$got" "a short OMP content survives intact"

echo "# slim: providerPayload never survives"
got=$(slim_one '{"message":{"role":"assistant","providerPayload":{"raw":"secretish"},"content":"hi"}}')
jq_is "$got" '.message.content' 'hi' "the assistant record itself survives"
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
