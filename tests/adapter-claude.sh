#!/bin/bash
# Contract tests for the claude adapter.
#
# This adapter invents no behavior — every subcommand delegates to the script
# that already implements it. What these tests pin is the CONTRACT: exit codes,
# atomic output, and the two path shapes a Claude session can have.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
A="$REPO/adapters/claude/adapter.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$A" ] || { printf '  FAIL - adapters/claude/adapter.sh missing or not executable\n'
                 printf '\npassed: 0   failed: 1\n'; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adclaude.XXXXXX")
# A real cwd to resolve against, created inside the sandbox so the test owns it.
proj="$tmp/proj a"          # a space, because NUL transport is supposed to allow it
mkdir -p "$proj"
projreal=$(cd "$proj" && pwd -P)

# Session at the normal depth: <root>/projects/<bucket>/<file>.jsonl
mkdir -p "$tmp/root/projects/-bucket"
S="$tmp/root/projects/-bucket/s1.jsonl"
printf '%s\n' \
  "{\"type\":\"user\",\"cwd\":\"$projreal\",\"message\":{\"content\":\"hello\"}}" \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' > "$S"

# Subagent transcript, which sits two levels deeper. CLAUDE.md is explicit that
# these are legitimate sessions to triage, so memory-root must handle both.
mkdir -p "$tmp/root/projects/-bucket/s1/subagents"
SUB="$tmp/root/projects/-bucket/s1/subagents/agent-x.jsonl"
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$projreal\",\"message\":{\"content\":\"sub\"}}" > "$SUB"

echo "# claude adapter: project returns the resolved cwd, not the bucket name"
assert_eq "$("$A" project "$S")" "$projreal" "resolved cwd from the transcript"
if "$A" project "$tmp/root/projects/-bucket/nope.jsonl" >/dev/null 2>&1; then
  no "a missing session exits nonzero"
else ok "a missing session exits nonzero"; fi

echo "# claude adapter: normalize is a verbatim copy for this harness"
out="$tmp/norm.jsonl"
if "$A" normalize "$S" "$out"; then ok "normalize exits 0"; else no "normalize exits 0"; fi
if cmp -s "$S" "$out"; then ok "normalize copied the file verbatim"; else no "normalize copied the file verbatim"; fi
if [ -e "$out.tmp" ]; then no "no .tmp left behind"; else ok "no .tmp left behind"; fi

echo "# claude adapter: a failed normalize leaves no partial output"
if "$A" normalize "$tmp/missing.jsonl" "$tmp/partial.jsonl" 2>/dev/null; then
  no "missing input exits nonzero"
else ok "missing input exits nonzero"; fi
if [ -e "$tmp/partial.jsonl" ]; then no "no partial output on failure"; else ok "no partial output on failure"; fi

echo "# claude adapter: memory-root walks up to the config dir, at either depth"
assert_eq "$("$A" memory-root "$S")"   "$(cd "$tmp/root" && pwd -P)" "normal session resolves to the root"
assert_eq "$("$A" memory-root "$SUB")" "$(cd "$tmp/root" && pwd -P)" "subagent transcript resolves to the same root"
if "$A" memory-root "$tmp/loose.jsonl" >/dev/null 2>&1; then
  no "a path with no projects/ ancestor exits nonzero"
else ok "a path with no projects/ ancestor exits nonzero"; fi

echo "# claude adapter: memory-root output is absolute and canonical"
mr=$("$A" memory-root "$S")
case "$mr" in /*) ok "memory-root is absolute" ;; *) no "memory-root is absolute (got: $mr)" ;; esac
assert_eq "$mr" "$(realpath "$mr")" "memory-root is already canonical"

echo "# claude adapter: stats writes a sidecar with numeric transcript_bytes"
if "$A" stats "$S" "$tmp/s1.stats.json" 2>/dev/null; then ok "stats exits 0"; else no "stats exits 0"; fi
if jq -e '.transcript_bytes | numbers' "$tmp/s1.stats.json" >/dev/null 2>&1; then
  ok "the sidecar has a numeric transcript_bytes"
else no "the sidecar has a numeric transcript_bytes"; fi

echo "# claude adapter: slim writes a reduced copy"
if "$A" slim "$S" "$tmp/slim.jsonl" 2>/dev/null; then ok "slim exits 0"; else no "slim exits 0"; fi
if [ -s "$tmp/slim.jsonl" ]; then ok "slim wrote output"; else no "slim wrote output"; fi

echo "# claude adapter: is-self defers to the one self-pollution predicate"
W="$tmp/root/projects/-bucket/worker.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Session transcript to analyze (literal absolute path): /x"}}' > "$W"
if "$A" is-self "$W"; then ok "an autodream worker transcript is ours"; else no "an autodream worker transcript is ours"; fi
if "$A" is-self "$S"; then no "a real session is not ours"; else ok "a real session is not ours"; fi

echo "# claude adapter: an unknown subcommand exits 2, never 0"
"$A" not-a-subcommand >/dev/null 2>&1; assert_eq "$?" "2" "unknown subcommand exits 2"

rm -rf "$tmp"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
