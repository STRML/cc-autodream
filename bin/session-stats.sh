#!/bin/bash
# Deterministic, model-free session statistics sidecar for cc-autodream L1 triage.

set -u

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <transcript.jsonl> <out.stats.json>" >&2
  exit 2
fi

transcript="$1"
output="$2"

[ -r "$transcript" ] || {
  echo "session-stats: transcript is not readable: $transcript" >&2
  exit 1
}

bytes=$(wc -c < "$transcript" | tr -d ' ')
mtime=$(stat -f %m "$transcript" 2>/dev/null) || {
  echo "session-stats: could not read transcript mtime: $transcript" >&2
  exit 1
}

mkdir -p "$(dirname "$output")" || exit 1

jq -R -s \
  --argjson transcript_bytes "${bytes:-0}" \
  --argjson transcript_mtime "${mtime:-0}" \
  '
  [
    split("\n")[]
    | fromjson?
    | select(type == "object")
  ] as $lines
  | [
      $lines[]
      | select(.type == "user" and .isMeta != true)
      | .message.content
      | select(
          type == "string"
          or (
            type == "array"
            and any(.[]?; .type == "text")
            and all(.[]?; .type != "tool_result")
          )
        )
    ] as $user_messages
  | (
      [
        $lines[]
        | select(.type == "user" and .isMeta != true)
        | select(
            (.message.content) as $c
            | ($c | type) == "string"
            or (
              ($c | type) == "array"
              and any($c[]?; .type == "text")
              and all($c[]?; .type != "tool_result")
            )
          )
        | .timestamp
        | select(type == "string")
        | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
      ] | sort
    ) as $user_turn_timestamps
  | [
      $lines[]
      | select(.isMeta != true and (.type == "user" or .type == "assistant"))
    ] as $turns
  | [
      $lines[]
      | select(.type == "assistant" and (.message.content | type) == "array")
      | .message.content[]
      | select(.type == "tool_use")
    ] as $tool_uses
  | [
      $lines[]
      | select(.type == "assistant")
      | .message.model
      | select(type == "string" and length > 0 and . != "<synthetic>")
    ] as $models
  | [
      $lines[]
      | select(has("timestamp"))
      | .timestamp
      | select(type == "string")
      | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
    ] as $timestamps
  | [
      $lines[]
      | select(.type == "assistant" and (.message.content | type) == "array")
      | .message.content[]
      | select(.type == "text" and (.text | type) == "string")
      | .text
    ]
    | join("") as $assistant_text
  | {
      user_message_count: ($user_messages | length),
      turn_count: ($turns | length),
      tool_call_count: ($tool_uses | length),
      tools_used: (
        $tool_uses
        | map(.name)
        | map(select(type == "string"))
        | unique
        | sort
      ),
      models_used: ($models | unique | sort),
      duration_minutes: (
        if ($timestamps | length) < 2 then 0
        else (((($timestamps | max) - ($timestamps | min)) / 60) * 10 | round) / 10
        end
      ),
      compliance_markers: {
        "RETRY-BUDGET": (($assistant_text | split("RETRY-BUDGET:") | length) - 1),
        "FETCH-PIVOT": (($assistant_text | split("FETCH-PIVOT:") | length) - 1)
      },
      transcript_bytes: $transcript_bytes,
      transcript_mtime: $transcript_mtime,
      isSidechain: (any($lines[]?; .isSidechain == true)),
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
