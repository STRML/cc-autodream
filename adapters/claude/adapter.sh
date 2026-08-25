#!/bin/bash
# Claude Code harness adapter.
#
# Every subcommand delegates to the script that already implements this
# behavior. Nothing is invented here. The point of this file is that run.sh
# stops knowing which harness it is talking to — not that anything about
# Claude ingest changes.
set -u

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$cmd" in

  enumerate) # $1=root $2=target-date $3=next-date -> NUL-delimited session paths
    find "$1" -type f -name '*.jsonl' \
         -newermt "$2 00:00:00" \
         ! -newermt "$3 00:00:00" \
         -print0 2>/dev/null
    ;;

  normalize) # $1=in $2=out
    # A Claude transcript is a flat list of turns, so normalisation is a copy.
    # It still writes through a .tmp and renames: the contract says a failed
    # subcommand leaves NO output, and a half-written file that a later step
    # reads as a whole session is worse than no session at all.
    [ -r "$1" ] || exit 1
    cp "$1" "$2.tmp" 2>/dev/null || { rm -f "$2.tmp"; exit 1; }
    mv "$2.tmp" "$2" 2>/dev/null || { rm -f "$2.tmp"; exit 1; }
    ;;

  project) # $1=session -> the session's real working directory
    [ -r "$1" ] || exit 1
    cwd=$(grep -om1 '"cwd":"[^"]*"' "$1" 2>/dev/null | head -1 | sed 's/^"cwd":"//;s/"$//')
    [ -n "$cwd" ] || exit 1
    realpath "$cwd" 2>/dev/null || exit 1
    ;;

  memory-root) # $1=session -> the Claude config dir that owns it
    # Two shapes exist and both are legitimate sessions to triage:
    #   <root>/projects/<bucket>/<file>.jsonl
    #   <root>/projects/<bucket>/<session>/subagents/agent-*.jsonl
    # so a fixed number of `..` hops is wrong. Walk up to the `projects`
    # directory instead; its parent is the config root. Failing here is
    # correct rather than defensive — an unresolvable memory root must not
    # reach the findings record, because it would later authorise a write
    # against an empty target.
    d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || exit 1
    while [ "$d" != "/" ]; do
      if [ "$(basename "$d")" = "projects" ]; then
        dirname "$d"
        exit 0
      fi
      d=$(dirname "$d")
    done
    exit 1
    ;;

  stats) exec "$BIN/session-stats.sh" "$1" "$2" ;;
  slim)  exec "$BIN/slim-transcript.sh" "$1" "$2" ;;

  is-self) # $1=session -> exit 0 if this is one of autodream's own transcripts
    # Delegated, never reimplemented: prune-self-sessions.sh is the single
    # source of truth for this predicate, and a marker added there must not
    # have to be remembered here too.
    exec "$BIN/prune-self-sessions.sh" --is-self "$1"
    ;;

  skills-inventory)
    for d in "$HOME"/.claude/skills/*/ "$HOME"/.claude/plugins/*/skills/*/; do
      [ -f "$d/SKILL.md" ] || continue
      printf '%s\n' "$(basename "$d")"
    done
    ;;

  *)
    printf 'claude adapter: unknown subcommand: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
