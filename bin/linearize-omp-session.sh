#!/bin/bash
# Collapse an OMP (oh-my-pi) session file into the live conversation, root-first.
#
# An OMP session JSONL is not a flat transcript like Claude Code's. Entries carry
# `id`/`parentId`, branching moves a leaf pointer instead of rewriting the file, and
# every abandoned branch stays on disk forever. Reading the file line-by-line therefore
# reports work the user explicitly backed out of as if it had happened — the same
# hazard the 2026-07-20 session-branches investigation refused to risk for Claude Code,
# except here it is guaranteed rather than hypothetical, and it is decidable: OMP's own
# `buildSessionContext` walks `parentId` from the leaf to the root, so "which branch is
# live" needs no length heuristic.
#
# This script does that walk and nothing else. Size reduction stays in
# slim-transcript.sh, which runs afterwards and (unlike this pass) only for oversized
# transcripts. Output is pure JSONL so that jq-based pass still applies: the leading
# metadata record is a real JSON object (`type: "autodream_meta"`), never a `#` banner,
# because slim-transcript.sh falls back wholesale on any unparseable line.
#
# Compaction and `/clear` (`reset_boundary`) entries are kept on the chain rather than
# applied. Triage wants what happened, including the pre-reset history that OMP's own
# full-transcript mode also retains; only ABANDONED branches are dropped.
#
# Exit status is a hard contract: nonzero means "this is not a linearizable OMP
# session", and the caller MUST skip the session rather than fall back to the raw file.
# Falling back would reinstate the abandoned-branch bug this script exists to prevent.
#
# Usage: linearize-omp-session.sh <src.jsonl> <dst.jsonl>
# Exit:  0 wrote dst | 1 usage/unreadable/jq missing | 2 not an OMP session | 3 jq failed

set -u

src="${1:?usage: linearize-omp-session.sh <src.jsonl> <dst.jsonl>}"
dst="${2:?usage: linearize-omp-session.sh <src.jsonl> <dst.jsonl>}"

[ -r "$src" ] || { echo "linearize-omp-session: cannot read $src" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "linearize-omp-session: jq not found" >&2; exit 1; }

# Format gate. An OMP file opens with a fixed-width title slot and then a `type:
# "session"` header carrying a string id (legacy files start at the header). Claude Code
# transcripts have no such entry, so this is a structural check, not a guess. Only the
# first few lines are read: the header is line 1 or 2 by construction.
if ! head -n 4 "$src" | jq -R -s -e '
      [ split("\n")[] | fromjson? | select(type == "object") ]
      | any(.[]; .type == "session" and (.id | type) == "string")
    ' >/dev/null 2>&1; then
  echo "linearize-omp-session: no omp session header in $src" >&2
  exit 2
fi

# ---- Nested-session provenance ----
# OMP stores a child session inside a directory named after its parent session file:
#   <bucket>/<stamp>_<id>.jsonl           the parent
#   <bucket>/<stamp>_<id>/__advisor.jsonl a child
# So "my directory, plus .jsonl, is a session file" identifies a child exactly.
#
# This matters because a child is the OMP analogue of a Claude sidechain and must be
# exempt from the noise gate: an advisor child holds real tool work but NO user turns,
# which is precisely what the gate discards. A `session_init` probe is not enough — on
# this host it covers all 16 spawned task children and none of the 20 `__advisor.jsonl`
# sessions, and the 2026-08-18 pilot duly threw away an advisor transcript carrying 26
# turns and 4 tool calls. Provenance holds for every nested session regardless of which
# entries it happens to contain.
parent_candidate="$(dirname "$src").jsonl"
if [ -f "$parent_candidate" ]; then
  omp_nested=true
  omp_parent="$parent_candidate"
else
  omp_nested=false
  omp_parent=""
fi
tmp="$dst.tmp.$$"
# Everything here fails closed. Lenient parsing is not an option: a skipped line can
# move the inferred leaf onto an abandoned branch, and the result — confidently wrong
# triage attributed to work the user rejected — is worse than losing one session, which
# the caller reports as a named normalization error. That also covers the torn last line
# a crash (or a scan racing an append) leaves behind.
#
# The walk is bounded by the entry count, so a cycle terminates instead of spinning; a
# cycle or a dangling parentId then surfaces as a chain whose root still has a parent,
# which is checked before anything is emitted.
if ! jq -R -s -c --arg src "$src" \
     --argjson nested "$omp_nested" --arg parent "$omp_parent" '
  def die($msg): ($msg + " in " + $src) | halt_error(4);

  [ split("\n")[] | select(test("^[[:space:]]*$") | not) ] as $raw
  | [ $raw[] | try fromjson catch null ] as $lines
  | if ($lines | any(. == null)) then die("unparseable JSONL line") else . end
  | if ($lines | any(type != "object")) then die("non-object JSONL entry") else . end
  | ( [ $lines[] | select(.type == "session") ] | first ) as $header
  # Entries are everything but the title slot and the header, both of which carry no id
  # and are folded into the metadata record below.
  | [ $lines[] | select(.type != "session" and .type != "title") ] as $entries
  | if ($entries | any((.id | type) != "string")) then die("entry without a string id") else . end
  | ($entries | length) as $n
  | ( $entries | map({key: .id, value: .}) | from_entries ) as $by_id
  # The leaf is the last entry in insertion order, which is what OMP itself falls back
  # to when no in-memory leaf pointer is available (the pointer is not persisted).
  | ( if $n == 0 then null else $entries[-1].id end ) as $leaf
  | ( reduce range(0; $n) as $_ (
        {cur: $leaf, seen: {}, acc: []};
        if .cur == null then .
        elif (.seen[.cur] // false) then .cur = null
        elif ($by_id[.cur] // null) == null then .cur = null
        else
          .seen[.cur] = true
          | .acc += [ $by_id[.cur] ]
          | .cur = ($by_id[.cur].parentId // null)
        end
      )
      | .acc | reverse
    ) as $chain
  # A complete chain ends at a root entry. Anything else means the walk stopped early on
  # a cycle or a parentId with no entry behind it, so the chain cannot be proven to be
  # the live conversation.
  | if ($chain | length) > 0 and ((($chain | first).parentId // null) != null)
    then die("broken parent chain (cycle or dangling parentId)") else . end
  | [ {
        type: "autodream_meta",
        source: "omp",
        source_path: $src,
        # Nested (child) sessions are the OMP analogue of a Claude sidechain. Recorded
        # from directory provenance, not from entry contents, because an advisor child
        # carries no session_init and no user turns — see the comment above the shell
        # detection. Consumers use this to exempt children from the noise gate.
        nested: $nested,
        parent_session_file: (if $parent == "" then null else $parent end),
        session_id: ($header.id // null),
        # cwd is project identity: it is the same real path across harnesses, whereas
        # the storage bucket name is source-specific.
        cwd: ($header.cwd // null),
        title: ($header.title // null),
        started_at: ($header.timestamp // null),
        entries: $n,
        on_path: ($chain | length),
        dropped: ($n - ($chain | length))
      } ]
    + $chain
  | .[]
' "$src" > "$tmp" 2>/dev/null; then
  rm -f "$tmp"
  echo "linearize-omp-session: refusing $src (unparseable or broken entry tree)" >&2
  exit 4
fi

if [ ! -s "$tmp" ]; then
  rm -f "$tmp"
  echo "linearize-omp-session: produced no output for $src" >&2
  exit 3
fi

mv "$tmp" "$dst" || { rm -f "$tmp"; exit 3; }
