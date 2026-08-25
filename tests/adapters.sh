#!/bin/bash
# Unit tests for bin/adapters.sh — loading, identity safety, containment.
#
# The security-relevant assertions here are the last three groups. Dispatch
# builds a command path from the adapter's directory name, so anything that can
# influence that name can influence what gets executed. The manifest is data,
# read with jq and never sourced; the basename is validated; and the directory
# is realpath-contained, because a basename check alone does not stop
# adapters/evil being a symlink to somewhere else entirely.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (got: [$2])" ;; esac; }

[ -f "$REPO/bin/adapters.sh" ] || {
  printf '  FAIL - bin/adapters.sh missing; the rest of this suite would be vacuous\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }

# shellcheck source=/dev/null
. "$REPO/bin/adapters.sh"

for fn in adapters_root adapters_list adapter_manifest_get adapter_run adapters_rejected; do
  declare -F "$fn" >/dev/null 2>&1 || {
    printf '  FAIL - %s is not defined; the rest of this suite would be vacuous\n' "$fn"
    printf '\npassed: 0   failed: 1\n'; exit 1; }
done

TMPROOTS=""
sandbox(){ local d; d=$(mktemp -d "${TMPDIR:-/tmp}/adapters.XXXXXX"); TMPROOTS="$TMPROOTS $d"; printf '%s' "$d"; }
mk_adapter(){ # $1=root $2=dirname $3=manifest name field
  mkdir -p "$1/$2"
  printf '{"name":"%s","engine_bin":"bash","writes_memory":true}\n' "$3" > "$1/$2/manifest.json"
  printf '#!/bin/bash\nprintf "ran %%s" "$1"\n' > "$1/$2/adapter.sh"
  chmod +x "$1/$2/adapter.sh"
}
# Each case gets a fresh reject log, since adapters_list runs in a command
# substitution and could not report rejections through a shell variable.
use(){ ADAPTERS_ROOT="$1"; ADAPTERS_REJECT_LOG="$1/.rejected"; : > "$ADAPTERS_REJECT_LOG"; }

echo "# adapters: a well-formed adapter loads and dispatches"
root=$(sandbox); mk_adapter "$root" claude claude; use "$root"
assert_eq "$(adapters_list)" "claude" "the adapter is listed"
assert_eq "$(adapter_manifest_get claude .engine_bin)" "bash" "a manifest value reads back"
assert_eq "$(adapter_run claude hello)" "ran hello" "dispatch reaches adapter.sh"

echo "# adapters: rejections survive command substitution"
root=$(sandbox); mk_adapter "$root" claude wrongname; use "$root"
assert_eq "$(adapters_list)" "" "a name/basename mismatch is refused"
has "claude" "$(adapters_rejected)" "the refusal is visible AFTER a \$(adapters_list) call"

echo "# adapters: an unsafe basename is refused"
root=$(sandbox); mk_adapter "$root" ".evil" ".evil"; use "$root"
assert_eq "$(adapters_list)" "" "a dot-prefixed basename is refused"
# Absent from the list is not the same as REFUSED. "$root"/*/ never matched a
# dot-prefixed directory, so .evil was invisible rather than rejected and
# adapters_rejected reported `none` — which reads as "nothing was refused".
has ".evil" "$(adapters_rejected)" "a dot-prefixed dir is RECORDED as refused, not merely skipped"
root=$(sandbox); mk_adapter "$root" "Bad" "Bad"; use "$root"
assert_eq "$(adapters_list)" "" "an uppercase basename is refused"

echo "# adapters: a symlink escaping the adapters root is refused"
root=$(sandbox); outside=$(sandbox); mk_adapter "$outside" evil evil
ln -s "$outside/evil" "$root/evil"; use "$root"
assert_eq "$(adapters_list)" "" "a symlinked adapter dir is refused"
has "evil" "$(adapters_rejected)" "the containment escape is recorded"

echo "# adapters: an adapter missing its manifest or adapter.sh is refused"
root=$(sandbox); mkdir -p "$root/bare"; use "$root"
assert_eq "$(adapters_list)" "" "a directory with neither file is refused"
root=$(sandbox); mk_adapter "$root" half half; rm "$root/half/adapter.sh"; use "$root"
assert_eq "$(adapters_list)" "" "a manifest with no adapter.sh is refused"

echo "# adapters: underscore-prefixed dirs are excluded from the default set"
root=$(sandbox); mk_adapter "$root" claude claude; mk_adapter "$root" _fixture _fixture; use "$root"
assert_eq "$(adapters_list)" "claude" "_fixture is not in the default set"
assert_eq "$(adapters_rejected)" "" "excluding a test adapter is not a rejection"

echo "# adapters: the manifest is data — \$HOME substitutes, nothing evaluates"
root=$(sandbox); mkdir -p "$root/claude"
canary="$root/pwned"
printf '{"name":"claude","session_roots_default":["$HOME/x`touch %s`$(touch %s)"]}\n' "$canary" "$canary" \
  > "$root/claude/manifest.json"
printf '#!/bin/bash\ntrue\n' > "$root/claude/adapter.sh"; chmod +x "$root/claude/adapter.sh"
use "$root"
got=$(adapter_manifest_get claude '.session_roots_default[0]')
has "$HOME/x" "$got" "\$HOME was substituted"
has 'touch'   "$got" "the shell metacharacters survive as literal text"
[ -e "$canary" ] && no "the manifest must not execute anything" || ok "the manifest executed nothing"

echo "# adapters: a malformed manifest is refused, not partially trusted"
root=$(sandbox); mkdir -p "$root/claude"
printf 'this is not json at all\n' > "$root/claude/manifest.json"
printf '#!/bin/bash\ntrue\n' > "$root/claude/adapter.sh"; chmod +x "$root/claude/adapter.sh"
use "$root"
assert_eq "$(adapters_list)" "" "unparseable JSON is refused"

# shellcheck disable=SC2086
rm -rf $TMPROOTS
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
