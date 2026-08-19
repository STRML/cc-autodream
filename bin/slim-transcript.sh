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

# Pre-pass: when jq is available, strip the bulky payloads inside tool-result entries
# (and base64 image data) before the line-based head/tail/truncate pass.
# Orchestrator/review-fan-out transcripts spend most of their bytes on tool results
# (entire diffs, file dumps, gh JSON), so cutting just those fields shrinks the file
# 5-20x while leaving the turn structure intact for fuzzy pattern-spotting. The
# line-based pass below still runs as a safety net (it caps stragglers like assistant
# turns that paste huge code blocks). Falls back transparently if jq isn't installed or
# the stream isn't pure JSONL.
#
# Two schemas are handled, discriminated by the entry's own `type`:
#   Claude Code — `{"type":"user"|"assistant", "message":{"content":[{"type":"tool_result"…
#   OMP         — `{"type":"message", "message":{"role":"toolResult", "content":[{"type":"text"…
# For OMP the payload is a plain text block on a `toolResult` message, and the tool's
# arguments ride in a `toolCall` block, so neither is reachable by the Claude rules.
# Both are truncated to a head rather than erased: the first line of a tool result
# ("Operation not permitted") is the sandbox_friction signal, and a toolCall's command
# text is what makes a tool_loop recognisable as the same command retried.
pre_src="$src"
pre_tmp=""
if command -v jq >/dev/null 2>&1; then
  pre_tmp="$dst.pre.jsonl"
  if jq -c --argjson head "${AUTODREAM_SLIM_PAYLOAD_HEAD:-200}" '
    def cap($n):
      if type == "string" and (length > $n)
      then .[0:$n] + " …[autodream: tool_result payload stripped]"
      else . end;

    if .type == "message" and ((.message.content | type) == "array") then
      # OMP entry.
      .message.content |= map(
        if .type == "toolCall" then
          .arguments |= (if type == "object" then map_values(cap($head)) else cap($head) end)
        elif .type == "image" then
          .data = "[autodream: image stripped]"
        else . end
      )
      | if (.message.role // "") == "toolResult" then
          .message.content |= map(if .type == "text" then .text |= cap($head) else . end)
          # details duplicates the payload as a structured object.
          | del(.message.details)
        else . end
    elif (.message.content | type) == "array" then
      # Claude Code entry.
      .message.content |= map(
        if .type == "tool_result" then
          # Replace the heavy content array with a one-line marker, preserve
          # tool_use_id + is_error so triage can still tell which call failed.
          .content = "[autodream: tool_result payload stripped]"
        elif .type == "image" or .type == "image_url" then
          .source = "[autodream: image stripped]"
        else . end
      )
    else . end
  ' "$src" > "$pre_tmp" 2>/dev/null && [ -s "$pre_tmp" ]; then
    pre_src="$pre_tmp"
    # Re-measure: head/tail/cap math below should reflect post-strip size.
    lines=$(wc -l < "$pre_src" | tr -d ' ')
  else
    rm -f "$pre_tmp"; pre_tmp=""
  fi
fi

{
  if [ "$lines" -le $((headn + tailn)) ]; then
    cut -c1-"$maxline" "$pre_src"
  else
    head -n "$headn" "$pre_src" | cut -c1-"$maxline"
    printf '...[%d of %d lines elided by autodream for size]...\n' $((lines - headn - tailn)) "$lines"
    tail -n "$tailn" "$pre_src" | cut -c1-"$maxline"
  fi
} | head -c "$cap" > "$dst"

[ -n "$pre_tmp" ] && rm -f "$pre_tmp"

printf '\n...[autodream slimmed this transcript: original %s bytes / %s lines; lines truncated to %s chars]...\n' \
  "$bytes" "$lines" "$maxline" >> "$dst"
