#!/bin/bash
# Slim an oversized Claude Code session transcript so the L1 haiku worker can read it.
#
# Some sessions are enormous (4500+ lines, ~10MB, base64 images and giant tool
# outputs). The worker can't even read 20 such lines without blowing the 25k-token
# Read limit, so it gives up and returns an error finding instead of triaging — and
# those big sessions are often the most interesting ones. This caps the damage:
#   1. truncate every line to a max width (kills base64 blobs / huge tool outputs),
#   2. keep head + tail and elide the middle (which is usually repetitive churn),
#   3. hard-cap total bytes as a final safety net.
# Triage is fuzzy pattern-spotting, not strict JSON parsing, so a lossy but
# representative transcript still yields useful findings. run.sh only invokes this
# for sessions over AUTODREAM_SLIM_BYTES; smaller ones are read verbatim.
#
# Usage: slim-transcript.sh <src.jsonl> <dst>
# Tunables (env): AUTODREAM_SLIM_MAXLINE (400 chars), _HEAD (400 lines),
#                 _TAIL (200 lines), _CAP (262144 bytes).
set -u

src="${1:?usage: slim-transcript.sh <src> <dst>}"
dst="${2:?usage: slim-transcript.sh <src> <dst>}"
maxline="${AUTODREAM_SLIM_MAXLINE:-400}"
headn="${AUTODREAM_SLIM_HEAD:-400}"
tailn="${AUTODREAM_SLIM_TAIL:-200}"
cap="${AUTODREAM_SLIM_CAP:-262144}"

[ -r "$src" ] || { echo "slim-transcript: cannot read $src" >&2; exit 1; }

lines=$(wc -l < "$src" | tr -d ' ')
bytes=$(wc -c < "$src" | tr -d ' ')

{
  if [ "$lines" -le $((headn + tailn)) ]; then
    cut -c1-"$maxline" "$src"
  else
    head -n "$headn" "$src" | cut -c1-"$maxline"
    printf '...[%d of %d lines elided by autodream for size]...\n' $((lines - headn - tailn)) "$lines"
    tail -n "$tailn" "$src" | cut -c1-"$maxline"
  fi
} | head -c "$cap" > "$dst"

printf '\n...[autodream slimmed this transcript: original %s bytes / %s lines; lines truncated to %s chars]...\n' \
  "$bytes" "$lines" "$maxline" >> "$dst"
