#!/bin/bash
# Deterministic, model-free session statistics sidecar for cc-autodream L1 triage.
#
# Handles both transcript schemas. Claude Code entries are flat (`type: "user"` /
# `"assistant"`); OMP (oh-my-pi) entries are tree nodes (`type: "message"` with a
# `message.role`) behind a `type: "session"` header. The two produce the same keys,
# because every consumer — the noise gate in run.sh above all — reads this sidecar
# without caring which harness wrote the session. Getting this wrong is not a degraded
# stat but a silent feature-off switch: OMP counted with Claude's selectors yields
# user_message_count 0, which sends every OMP session down the below_noise_gate path
# without ever reaching a model.
#
# For OMP, pass the LINEARIZED transcript (bin/linearize-omp-session.sh). Run against a
# raw OMP file these counts include branches the user abandoned, which is exactly the
# over-count the linearizer exists to remove.

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

# ---- OMP (oh-my-pi) sessions ------------------------------------------------------
# Structural detection, not a guess, and it must accept BOTH shapes this script is fed:
#   raw        — `type:"session"` header with a string id (title slot, then header)
#   linearized — bin/linearize-omp-session.sh folds that header into its leading
#                `type:"autodream_meta"` record, so the raw header is gone
# The linearized file is the production input. Detecting only the raw header would send
# it down the Claude branch, which reports zero user turns and therefore gates every OMP
# session away before a model ever sees it. Claude Code transcripts carry neither entry.
if head -n 4 "$transcript" | jq -R -s -e '
     [ split("\n")[] | fromjson? | select(type == "object") ]
     | any(.[];
         (.type == "session" and (.id | type) == "string")
         or (.type == "autodream_meta" and .source == "omp")
       )
   ' >/dev/null 2>&1; then
  jq -R -s \
    --argjson transcript_bytes "${bytes:-0}" \
    --argjson transcript_mtime "${mtime:-0}" \
    '
    def ts: select(type == "string") | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty;

    [ split("\n")[] | fromjson? | select(type == "object") ] as $lines
    | [ $lines[] | select(.type == "message") ] as $msgs
    # A spawned subagent session records its own init entry. It is the OMP analogue of
    # the Claude isSidechain flag: legitimate work, often short on user turns, so like
    # sidechains it is never noise-gated.
    | (any($lines[]?; .type == "session_init")) as $is_subagent
    # Real user input only: an entry whose attribution is "agent" was injected by the
    # harness (steering, hook output), not typed by the user.
    | [ $msgs[]
        | select((.message.role) == "user")
        | select((.message.attribution // "user") == "user")
        | select((.message.content | type) == "array" and any(.message.content[]?; .type == "text"))
      ] as $user_entries
    | ( [ $user_entries[] | .timestamp | ts ] | sort ) as $user_turn_timestamps
    | [ $msgs[] | select((.message.role) == "user" or (.message.role) == "assistant") ] as $turns
    | [ $msgs[]
        | select((.message.role) == "assistant" and (.message.content | type) == "array")
        | .message.content[]
        | select(.type == "toolCall")
      ] as $tool_calls
    | [ $msgs[] | select((.message.role) == "assistant") | .message.model | select(type == "string" and length > 0) ] as $msg_models
    | [ $lines[] | select(.type == "model_change") | .model | select(type == "string" and length > 0) ] as $changed_models
    | ( if ($msg_models | length) > 0 then $msg_models else $changed_models end ) as $models
    | [ $lines[] | select(.type != "session" and .type != "title" and .type != "autodream_meta") | .timestamp | ts ] as $timestamps
    # No compliance_markers here on purpose. The markers are a Claude-rules artifact,
    # origin/retire-compliance-markers removes them from this script outright, and that
    # branch would merge cleanly over an OMP copy of the counting logic — leaving retired
    # telemetry alive only for OMP. PROMPT.md already defaults the key to 0 when a
    # findings record omits it, so absence costs nothing.
    | {
        user_message_count: ($user_entries | length),
        turn_count: ($turns | length),
        tool_call_count: ($tool_calls | length),
        tools_used: ($tool_calls | map(.name) | map(select(type == "string")) | unique | sort),
        models_used: ($models | unique | sort),
        duration_minutes: (
          if ($timestamps | length) < 2 then 0
          else (((($timestamps | max) - ($timestamps | min)) / 60) * 10 | round) / 10
          end
        ),
        transcript_bytes: $transcript_bytes,
        transcript_mtime: $transcript_mtime,
        isSidechain: $is_subagent,
        user_turn_timestamps: $user_turn_timestamps
      }
    ' "$transcript" > "$output"
  exit
fi

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
      # Marker counting is top-level-session-only (advisor-cabinet spec):
      # sidechain (subagent) assistant text never contributes markers.
      | select(.type == "assistant" and .isSidechain != true and (.message.content | type) == "array")
      | .message.content[]
      | select(.type == "text" and (.text | type) == "string")
      | .text
    ]
    | join("\n") as $assistant_text
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
      compliance_markers: (
        # Line-start counting (2026-07-20, advisor-cabinet spec): a marker counts
        # only when it BEGINS a line of assistant text and is outside a ``` fence,
        # so quoted reports and rule-file examples cannot inflate the counts.
        reduce ($assistant_text | split("\n"))[] as $l (
          {fence: false, rb: 0, fp: 0, dl: 0, dok: 0};
          if ($l | test("^\\s*```")) then .fence = (.fence | not)
          elif .fence then .
          elif ($l | startswith("RETRY-BUDGET:")) then .rb += 1
          elif ($l | startswith("FETCH-PIVOT:")) then .fp += 1
          elif ($l | startswith("DELEGATED:")) then .dl += 1
          elif ($l | startswith("DIRECT-OK:")) then .dok += 1
          else . end
        )
        | {"RETRY-BUDGET": .rb, "FETCH-PIVOT": .fp, "DELEGATED": .dl, "DIRECT-OK": .dok}
      ),
      transcript_bytes: $transcript_bytes,
      transcript_mtime: $transcript_mtime,
      isSidechain: (any($lines[]?; .isSidechain == true)),
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
