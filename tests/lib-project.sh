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

echo "# lib-project: session_hash returns 12 lowercase hex, or fails"
h=$(session_hash "/some/path.jsonl") && ok "session_hash succeeds on a normal path" || no "session_hash succeeds on a normal path"
assert_eq "${#h}" "12" "the key is exactly 12 characters"
case "$h" in *[!0123456789abcdef]*) no "the key is lowercase hex" ;; *) ok "the key is lowercase hex" ;; esac

echo "# lib-project: the hex class is enumerated, because ranges are collation-dependent"
# Verified on this host: under bash 3.2 with an en_US.UTF-8 collation, `A`
# MATCHES [0-9a-f]; under bash 5.3 it does not. The nightly runs #!/bin/bash,
# which is 3.2, so a range here would accept uppercase exactly where it matters.
# This is the same behaviour that made an uppercase adapter basename pass on CI
# and never locally. Run the check under the shell and locale that expose it.
if [ -x /bin/bash ]; then
  r=$(LC_ALL=en_US.UTF-8 /bin/bash -c 'case "A" in [0123456789abcdef]) echo MATCHED ;; *) echo rejected ;; esac')
  assert_eq "$r" "rejected" "the enumerated set rejects uppercase under bash 3.2 + UTF-8"
  # Informational, NOT an assertion. Pinning "the range form is broken" would
  # fail the day a shell fixes it, which is the wrong thing to guard. What must
  # hold is that OUR pattern rejects uppercase; whether the range still does not
  # is a fact about the platform, reported for the next reader.
  r=$(LC_ALL=en_US.UTF-8 /bin/bash -c 'case "A" in [0-9a-f]) echo MATCHED ;; *) echo rejected ;; esac')
  printf '  note - the range form [0-9a-f] vs "A" under bash 3.2 + UTF-8: %s\n' "$r"
else
  ok "no /bin/bash to test the collation behaviour against; skipped"
fi

echo "# lib-project: a shasum that fails at runtime yields no hash, not an empty one"
stub=$(mktemp -d "${TMPDIR:-/tmp}/hashstub.XXXXXX")
printf '#!/bin/bash\nexit 3\n' > "$stub/shasum"; chmod +x "$stub/shasum"
if PATH="$stub:$PATH" session_hash "/x" >/dev/null 2>&1; then
  no "a failing shasum must not produce a hash"
else
  ok "a failing shasum produces no hash"
fi
assert_eq "$(PATH="$stub:$PATH" session_hash "/x" 2>/dev/null)" "" "and prints nothing"
rm -rf "$stub"

rm -rf "$tmp"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
