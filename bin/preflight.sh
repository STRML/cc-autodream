#!/bin/bash
# Shared-dependency preflight. Runs before anything is enumerated, and a
# failure here is a hard stop rather than a degraded run.
#
# None of these are new assumptions — run.sh already depends on all four:
#
#   jq        every findings record, sidecar and manifest is parsed with it
#   shasum    bin/run.sh:468 and bin/run.sh:540 key each artifact by sha1
#   python3   bin/run.sh:924 normalises project identity
#   realpath  NEW: adapter containment and cwd canonicalisation
#
# The `shasum` case is the one worth stating out loud, because it is the only
# dependency whose absence produces no error at all. `h=$(printf '%s' "$s" |
# shasum -a 1 | cut -c1-12)` assigns the empty string when shasum is missing,
# so every session in the night writes to the SAME findings filename and the
# run ends with one record where it should have had a hundred. Nothing in the
# existing code notices.
#
# `realpath` is security-critical rather than convenient: it does adapter
# directory containment and cwd canonicalisation. A host that reached adapter
# loading without it would fall back to weaker containment, which is exactly
# the failure the check exists to prevent — so it is never a degraded path.
set -u

L2_BIN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --l2-bin) L2_BIN="${2:-}"; shift 2 ;;
    *)        shift ;;
  esac
done

MISSING_KEYS=""
missing=0

need() { # $1=command $2=what its absence costs
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'MISSING: %s — %s\n' "$1" "$2" >&2
    MISSING_KEYS="${MISSING_KEYS:+$MISSING_KEYS,}$1"
    missing=$((missing + 1))
  fi
}

need jq       "every findings record, sidecar and adapter manifest is parsed with it"
need shasum   "the artifact key is sha1 of the session path; without it the hash is empty and every session collides on one filename, silently"
need python3  "project normalisation and the stats sidecars"
need realpath "adapter directory containment and cwd canonicalisation; without it containment is weaker, which is the failure this check exists to prevent"

if [ -n "$L2_BIN" ] && ! command -v "$L2_BIN" >/dev/null 2>&1; then
  printf 'MISSING: %s — the configured L2 engine; no report is possible without it\n' "$L2_BIN" >&2
  MISSING_KEYS="${MISSING_KEYS:+$MISSING_KEYS,}l2_engine"
  missing=$((missing + 1))
fi

if [ "$missing" -ne 0 ]; then
  printf 'preflight_missing: %s\n' "$MISSING_KEYS"
  exit 1
fi
exit 0
