#!/bin/bash
# THE adapter contract, run against every adapter rather than described once.
#
# The same assertions execute for `claude` and for `_fixture`. That is the whole
# point: a contract that only ever runs against the adapter it was written
# alongside is a description of that adapter, and it will keep passing on the
# day someone adds a Claude-shaped assumption to shared code. `_fixture` uses a
# session format resembling neither real harness, so an assumption that leaked
# in fails here immediately.
#
# When a third adapter arrives (omp, codex, pi), add one `run_contract` line.
# If that is all it takes, the seam is real.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# --- per-adapter fixture makers -------------------------------------------
# Each prints a session path for its harness's own format into $1.
mk_session_claude(){ # $1=dir $2=cwd
  mkdir -p "$1/root/projects/-bucket"
  local f="$1/root/projects/-bucket/s.jsonl"
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$2\",\"message\":{\"content\":\"hi\"}}" > "$f"
  printf '%s' "$f"
}
mk_session__fixture(){ # $1=dir $2=cwd
  mkdir -p "$1/store"
  local f="$1/store/s.fixture"
  printf '{"cwd":"%s","turns":2}\n' "$2" > "$f"
  printf '%s' "$f"
}

run_contract(){ # $1=adapter name
  local name="$1"
  local A="$REPO/adapters/$name/adapter.sh"
  echo "# contract [$name]"

  if [ ! -x "$A" ]; then no "[$name] adapter.sh exists and is executable"; return; fi
  ok "[$name] adapter.sh exists and is executable"

  # The manifest is data and must parse, and its name must match the directory.
  if jq -e . "$REPO/adapters/$name/manifest.json" >/dev/null 2>&1; then
    ok "[$name] manifest.json is valid JSON"
  else no "[$name] manifest.json is valid JSON"; fi
  assert_eq "$(jq -r .name "$REPO/adapters/$name/manifest.json")" "$name" "[$name] manifest name matches its directory"
  if [ -s "$REPO/adapters/$name/facts.md" ]; then
    ok "[$name] facts.md exists and is non-empty"
  else no "[$name] facts.md exists and is non-empty"; fi

  local tmp proj projreal S
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")
  proj="$tmp/work dir"; mkdir -p "$proj"          # a space: NUL transport must allow it
  projreal=$(cd "$proj" && pwd -P)
  S=$("mk_session_$name" "$tmp" "$projreal")

  # --- project ---
  assert_eq "$("$A" project "$S")" "$projreal" "[$name] project prints the resolved cwd"
  if "$A" project "$tmp/nope" >/dev/null 2>&1; then
    no "[$name] project on a missing session exits nonzero"
  else ok "[$name] project on a missing session exits nonzero"; fi

  # --- normalize: atomic, and nothing left behind on failure ---
  if "$A" normalize "$S" "$tmp/n.out" 2>/dev/null; then ok "[$name] normalize exits 0"
  else no "[$name] normalize exits 0"; fi
  if [ -s "$tmp/n.out" ]; then ok "[$name] normalize wrote output"; else no "[$name] normalize wrote output"; fi
  if [ -e "$tmp/n.out.tmp" ]; then no "[$name] normalize left no .tmp"; else ok "[$name] normalize left no .tmp"; fi
  if "$A" normalize "$tmp/nope" "$tmp/bad.out" 2>/dev/null; then
    no "[$name] normalize on bad input exits nonzero"
  else ok "[$name] normalize on bad input exits nonzero"; fi
  if [ -e "$tmp/bad.out" ]; then no "[$name] no partial output on failure"; else ok "[$name] no partial output on failure"; fi

  # --- stats: a sidecar file with a numeric transcript_bytes ---
  if "$A" stats "$S" "$tmp/s.stats.json" 2>/dev/null; then ok "[$name] stats exits 0"
  else no "[$name] stats exits 0"; fi
  if jq -e '.transcript_bytes | numbers' "$tmp/s.stats.json" >/dev/null 2>&1; then
    ok "[$name] the sidecar carries a numeric transcript_bytes"
  else no "[$name] the sidecar carries a numeric transcript_bytes"; fi

  # --- slim ---
  if "$A" slim "$S" "$tmp/sl.out" 2>/dev/null; then ok "[$name] slim exits 0"; else no "[$name] slim exits 0"; fi
  if [ -s "$tmp/sl.out" ]; then ok "[$name] slim wrote output"; else no "[$name] slim wrote output"; fi

  # --- is-self: must answer, and must not claim an ordinary session ---
  "$A" is-self "$S" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then ok "[$name] is-self answers 0 or 1"
  else no "[$name] is-self answers 0 or 1 (got $rc)"; fi
  if "$A" is-self "$S" >/dev/null 2>&1; then
    no "[$name] an ordinary session is not claimed as ours"
  else ok "[$name] an ordinary session is not claimed as ours"; fi

  # --- memory-root: empty is legal ONLY for a non-writing adapter ---
  local writes mr
  writes=$(jq -r '.writes_memory' "$REPO/adapters/$name/manifest.json")
  mr=$("$A" memory-root "$S" 2>/dev/null || true)
  if [ "$writes" = "true" ]; then
    case "$mr" in
      /*) ok "[$name] writes_memory:true, so memory-root is absolute" ;;
      *)  no "[$name] writes_memory:true, so memory-root is absolute (got: [$mr])" ;;
    esac
    assert_eq "$mr" "$(realpath "$mr" 2>/dev/null)" "[$name] memory-root is canonical"
  else
    assert_eq "$mr" "" "[$name] writes_memory:false, so memory-root is empty"
  fi

  # --- unknown subcommand ---
  "$A" not-a-subcommand >/dev/null 2>&1
  assert_eq "$?" "2" "[$name] an unknown subcommand exits 2"

  rm -rf "$tmp"
}

run_contract claude
run_contract _fixture

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
