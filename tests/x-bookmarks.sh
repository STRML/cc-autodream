#!/bin/bash
# Tests for bin/x-bookmarks.sh — the fetch, the read state, and every way it degrades.
#
# No network. `curl` is shimmed by a fake earlier on PATH (same trick tests/review-skip.sh
# uses for `claude`), and the queryId cache is pre-seeded so the bundle-scraping walk is
# skipped — that walk is against a live third party and cannot be meaningfully faked.
#
# What is actually worth pinning here is everything downstream of the HTTP call, because
# that is where the two bugs found during development lived: emit ordering came out
# oldest-first, and mark-read silently no-opped on every line. Both were invisible to a
# smoke test and both would have quietly wasted the feature.
#
# Usage:  tests/x-bookmarks.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BIN="$REPO/bin/x-bookmarks.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_file(){     [ -f "$1" ] && ok "$2" || no "$2 (missing: $1)"; }
assert_grep(){     grep -q "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){   grep -q "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }
assert_eq(){       [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# A two-bookmark page in the real response shape: bookmark_timeline_v2 -> instructions ->
# entries -> content.itemContent.tweet_results.result, author under core.user_results.
# The ids are deliberately NOT in ascending file order, so an emit that trusts file
# position instead of sorting by id fails this fixture.
fixture_page(){ cat <<'JSON'
{"data":{"bookmark_timeline_v2":{"timeline":{"instructions":[{"type":"TimelineAddEntries","entries":[
{"entryId":"tweet-100","content":{"itemContent":{"tweet_results":{"result":{
  "rest_id":"100",
  "core":{"user_results":{"result":{"core":{"screen_name":"olderauthor","name":"Older"}}}},
  "legacy":{"full_text":"the older post","created_at":"Mon Jul 28 10:00:00 +0000 2026","entities":{"urls":[]}}}}}}},
{"entryId":"tweet-200","content":{"itemContent":{"tweet_results":{"result":{
  "rest_id":"200",
  "core":{"user_results":{"result":{"core":{"screen_name":"newerauthor","name":"Newer"}}}},
  "legacy":{"full_text":"the newer post","created_at":"Fri Aug 01 10:00:00 +0000 2026","entities":{"urls":[{"expanded_url":"https://example.com/article"}]}}}}}}},
{"entryId":"cursor-bottom-0","content":{"cursorType":"Bottom","value":"CURSOR_END"}}
]}]}}}}
JSON
}

# Fake curl. Honours -o <file> and -w '%{http_code}' the way the script uses them:
# writes MOCK_BODY (or the fixture) to the -o path and prints MOCK_CODE.
make_curl_shim(){ # $1=bindir
  mkdir -p "$1"
  cat > "$1/curl" <<'SH'
#!/bin/bash
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && { if [ -n "${MOCK_BODY:-}" ] && [ -f "${MOCK_BODY}" ]; then cat "$MOCK_BODY" > "$out"; else printf '{}' > "$out"; fi; }
printf '%s' "${MOCK_CODE:-200}"
exit 0
SH
  chmod +x "$1/curl"
}

# Fresh sandbox with credentials and a pre-seeded queryId so detection is skipped.
setup(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/xbmt.XXXXXX")
  mkdir -p "$root/state" "$root/findings" "$root/bin"
  printf 'X_AUTH_TOKEN=token\nX_CT0=csrf\n' > "$root/creds"; chmod 600 "$root/creds"
  printf 'CACHEDQUERYID' > "$root/state/query-id"
  make_curl_shim "$root/bin"
  fixture_page > "$root/page.json"
  printf '%s' "$root"
}
run_bm(){ # $1=root, rest = args ; MOCK_CODE/MOCK_BODY/X_CREDS_FILE inherited
  local root="$1"; shift
  # AUTODREAM_DIR and AUTODREAM_CONFIG are pinned into the sandbox because the script
  # sources its config: without this the suite would read the developer's real
  # ~/.claude/autodream/config and inherit whatever they set there.
  PATH="$root/bin:$PATH" \
  AUTODREAM_DIR="$root" AUTODREAM_CONFIG="$root/no-such-config" \
  X_CREDS_FILE="${X_CREDS_FILE:-$root/creds}" X_STATE_DIR="$root/state" \
  X_MAX_PAGES=1 MOCK_BODY="${MOCK_BODY:-$root/page.json}" \
  bash "$BIN" "$@" > "$root/out.txt" 2>&1
}

# ---------------------------------------------------------------------------

test_not_configured(){
  echo "# no credentials -> a not-configured stub, an empty manifest, exit 0"
  local root; root=$(setup)
  X_CREDS_FILE="$root/does-not-exist" run_bm "$root" collect "$root/findings"
  assert_eq "$?" "0" "exits 0 with no credentials"
  assert_file "$root/findings/x-bookmarks.md" "the output file is written anyway"
  assert_grep "$root/findings/x-bookmarks.md" "not configured" "it says the feature is not configured"
  assert_nogrep "$root/findings/x-bookmarks.md" "fetch failed" "an absent config is not reported as a failure"
  assert_eq "$(wc -c < "$root/findings/x-bookmarks-manifest.txt" | tr -d ' ')" "0" "the manifest is empty"
  rm -rf "$root"
}

test_auth_failure(){
  echo "# HTTP 401 -> the fetch-failed header names the re-paste remediation, exit 0"
  local root; root=$(setup)
  MOCK_CODE=401 run_bm "$root" collect "$root/findings"
  assert_eq "$?" "0" "exits 0 so the nightly run continues"
  assert_grep "$root/findings/x-bookmarks.md" "^# x-bookmarks: fetch failed" "the first line is the failure header"
  assert_grep "$root/findings/x-bookmarks.md" "auth_token" "the remediation names the cookies to re-paste"
  rm -rf "$root"
}

test_stale_queryid_clears_cache(){
  echo "# HTTP 400 -> the cached queryId is dropped so the next run re-scrapes it"
  local root; root=$(setup)
  MOCK_CODE=400 run_bm "$root" collect "$root/findings"
  [ ! -f "$root/state/query-id" ] && ok "the stale queryId cache was cleared" || no "the stale queryId cache survived"
  assert_grep "$root/findings/x-bookmarks.md" "400" "the report names the status code"
  rm -rf "$root"
}

test_parse_and_emit(){
  echo "# a real-shaped response parses into markdown, a manifest, and state"
  local root; root=$(setup)
  run_bm "$root" collect "$root/findings"
  local md="$root/findings/x-bookmarks.md"
  assert_grep "$md" "@newerauthor"       "the author handle is read from user core"
  assert_grep "$md" "the newer post"     "the post text is present"
  assert_grep "$md" "x.com/newerauthor/status/200" "the permalink is built from handle and id"
  assert_grep "$md" "example.com/article" "the expanded link is included"
  assert_eq "$(wc -l < "$root/findings/x-bookmarks-manifest.txt" | tr -d ' ')" "2" "both bookmarks are in the manifest"
  assert_eq "$(wc -l < "$root/state/seen.jsonl" | tr -d ' ')" "2" "both bookmarks are recorded in state"
  rm -rf "$root"
}

test_newest_first(){
  echo "# emit order is by tweet id descending, not by position in the state file"
  local root; root=$(setup)
  run_bm "$root" collect "$root/findings"
  assert_eq "$(head -1 "$root/findings/x-bookmarks-manifest.txt")" "200" "the newer bookmark is listed first"
  rm -rf "$root"
}

test_mark_read_then_not_relisted(){
  echo "# once marked read, a bookmark is not offered again"
  local root; root=$(setup)
  run_bm "$root" collect "$root/findings"
  run_bm "$root" mark-read "$root/findings"
  assert_eq "$(grep -c '"read_on":null' "$root/state/seen.jsonl")" "0" "no bookmark is left unread"
  assert_eq "$(wc -l < "$root/state/seen.jsonl" | tr -d ' ')" "2" "marking read does not drop state rows"

  mkdir -p "$root/findings2"
  run_bm "$root" collect "$root/findings2"
  assert_nogrep "$root/findings2/x-bookmarks.md" "the newer post" "an already-read bookmark is not re-listed"
  assert_eq "$(wc -c < "$root/findings2/x-bookmarks-manifest.txt" | tr -d ' ')" "0" "the second manifest is empty"
  rm -rf "$root"
}

test_mark_read_idempotent(){
  echo "# mark-read runs twice without corrupting state"
  local root; root=$(setup)
  run_bm "$root" collect "$root/findings"
  run_bm "$root" mark-read "$root/findings"
  local before; before=$(cat "$root/state/seen.jsonl")
  run_bm "$root" mark-read "$root/findings"
  assert_eq "$(cat "$root/state/seen.jsonl")" "$before" "a second mark-read changes nothing"
  rm -rf "$root"
}

test_mark_read_no_manifest(){
  echo "# mark-read with no manifest is a no-op, not an error"
  local root; root=$(setup)
  run_bm "$root" collect "$root/findings"
  mkdir -p "$root/empty"
  run_bm "$root" mark-read "$root/empty"
  assert_eq "$?" "0" "exits 0 with no manifest"
  assert_eq "$(grep -c '"read_on":null' "$root/state/seen.jsonl")" "2" "state is untouched"
  rm -rf "$root"
}

test_unread_survive_a_failed_fetch(){
  echo "# a fetch failure still serves bookmarks captured earlier, with a banner"
  local root; root=$(setup)
  run_bm "$root" collect "$root/findings"          # populate state, leave unread
  mkdir -p "$root/findings2"
  MOCK_CODE=401 run_bm "$root" collect "$root/findings2"
  local md="$root/findings2/x-bookmarks.md"
  assert_grep "$md" "the newer post" "previously-captured unread bookmarks are still offered"
  assert_grep "$md" "could not reach X" "the staleness is disclosed"
  assert_eq "$(wc -l < "$root/findings2/x-bookmarks-manifest.txt" | tr -d ' ')" "2" "they are still manifested for mark-read"
  rm -rf "$root"
}

test_state_not_duplicated(){
  echo "# collecting the same page twice does not duplicate state rows"
  local root; root=$(setup)
  run_bm "$root" collect "$root/findings"
  mkdir -p "$root/findings2"
  run_bm "$root" collect "$root/findings2"
  assert_eq "$(wc -l < "$root/state/seen.jsonl" | tr -d ' ')" "2" "state still holds exactly two rows"
  rm -rf "$root"
}

test_text_is_capped(){
  echo "# an overlong post is truncated so a thread cannot blow the token budget"
  local root; root=$(setup)
  local long; long=$(printf 'x%.0s' $(seq 1 3000))
  jq --arg t "$long" '.data.bookmark_timeline_v2.timeline.instructions[0].entries[0].content.itemContent.tweet_results.result.legacy.full_text = $t' \
    "$root/page.json" > "$root/page-long.json"
  MOCK_BODY="$root/page-long.json" X_MAX_TEXT=100 run_bm "$root" collect "$root/findings"
  assert_grep "$root/findings/x-bookmarks.md" '\[…\]' "the truncation marker is present"
  [ "$(wc -c < "$root/findings/x-bookmarks.md")" -lt 2000 ] \
    && ok "the emitted file stayed small" || no "the emitted file was not truncated"
  rm -rf "$root"
}

echo "x-bookmarks.sh tests"
test_not_configured
test_auth_failure
test_stale_queryid_clears_cache
test_parse_and_emit
test_newest_first
test_mark_read_then_not_relisted
test_mark_read_idempotent
test_mark_read_no_manifest
test_unread_survive_a_failed_fetch
test_state_not_duplicated
test_text_is_capped

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
