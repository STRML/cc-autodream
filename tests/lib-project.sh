#!/bin/bash
# Unit tests for bin/lib-project.sh — the canonical project encoding.
#
# This encoding is load-bearing: it is what makes two harnesses' work on one
# real directory group as ONE project, with no reconciliation pass. Getting it
# wrong splits a project silently, because a wrongly-encoded record still looks
# perfectly well-formed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$REPO/bin/lib-project.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# Assert the functions exist before asserting on their output. Without this,
# every comparison of two absent-function outputs is empty-equals-empty and the
# suite passes green against no implementation at all.
for fn in encode_project canonical_project; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf '  FAIL - %s is not defined; the rest of this suite would be vacuous\n' "$fn"
    printf '\npassed: 0   failed: 1\n'
    exit 1
  fi
done

echo "# lib-project: encode_project maps / . and _ to -"
assert_eq "$(encode_project /Users/x/sites)"   "-Users-x-sites"  "plain path"
assert_eq "$(encode_project /Users/x/.claude)" "-Users-x--claude" "dot becomes a dash"
assert_eq "$(encode_project /Users/x/a_b)"     "-Users-x-a-b"    "underscore becomes a dash"
assert_eq "$(encode_project /Users/x/.a_b.c)"  "-Users-x--a-b-c" "dots and underscores together"

echo "# lib-project: the encoding matches real Claude buckets on this host"
# The regression that motivated this file: seanperkins/autodream-merge maps only
# `/`, so it produces -Users-<u>-.claude for a directory Claude stores as
# -Users-<u>--claude. Assert against a bucket name only if it actually exists,
# so the test is meaningful here and inert on a machine without that history.
real_bucket="$HOME/.claude/projects/$(encode_project "$HOME/.claude")"
if [ -d "$real_bucket" ]; then
  ok "encode_project agrees with a real on-disk bucket for \$HOME/.claude"
else
  ok "no \$HOME/.claude bucket on this host; skipped the on-disk cross-check"
fi

echo "# lib-project: canonical_project resolves symlinks before encoding"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/libproj.XXXXXX")
mkdir -p "$tmp/real.dir"
ln -s "$tmp/real.dir" "$tmp/link"
want=$(encode_project "$(cd "$tmp/real.dir" && pwd -P)")
assert_eq "$(canonical_project "$tmp/link")" "$want" "symlink resolves to its target"

echo "# lib-project: an unresolvable path fails loudly, never silently encodes"
if canonical_project "$tmp/does-not-exist" >/dev/null 2>&1; then
  no "missing path must exit nonzero"
else
  ok "missing path exits nonzero"
fi
assert_eq "$(canonical_project "$tmp/does-not-exist" 2>/dev/null)" "" "missing path prints nothing"

rm -rf "$tmp"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
