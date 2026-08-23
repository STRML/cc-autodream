#!/bin/bash
# Unit tests for bin/preflight.sh.
#
# These dependencies are not new — run.sh already relies on all of them. They
# were simply never checked, and one fails in a way that destroys a night's
# corpus without erroring: with `shasum` absent the artifact hash assignment
# yields an empty string, so every session targets the same findings filename.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PF="$REPO/bin/preflight.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (got: $2)" ;; esac; }

[ -x "$PF" ] || { printf '  FAIL - bin/preflight.sh missing or not executable\n\npassed: 0   failed: 1\n'; exit 1; }

echo "# preflight: a host with every dependency present exits 0"
if "$PF" --l2-bin bash >/dev/null 2>&1; then ok "exits 0 when all present"; else no "exits 0 when all present"; fi

echo "# preflight: a missing L2 engine is a hard failure, named"
out=$("$PF" --l2-bin definitely-not-a-real-binary-xyz 2>&1); rc=$?
assert_eq "$rc" "1" "exits 1 on a missing L2 engine"
has "definitely-not-a-real-binary-xyz" "$out" "names the missing engine"

echo "# preflight: missing shared dependencies are named, not silently skipped"
# An empty PATH dir hides every external command from `command -v`.
empty=$(mktemp -d "${TMPDIR:-/tmp}/pf.XXXXXX")
out=$(PATH="$empty" "$PF" --l2-bin bash 2>&1); rc=$?
assert_eq "$rc" "1" "exits 1 when dependencies are missing"
has "jq"       "$out" "names jq"
has "shasum"   "$out" "names shasum"
has "python3"  "$out" "names python3"
has "realpath" "$out" "names realpath"

echo "# preflight: the reason is carried, not just the name"
has "one filename" "$out" "says what a missing shasum actually costs"
has "containment"  "$out" "says why realpath is security-critical"

echo "# preflight: the failure is machine-readable for run-stats"
has "preflight_missing:" "$out" "emits a preflight_missing key"

rm -rf "$empty"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
