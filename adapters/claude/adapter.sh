#!/bin/bash
# Claude Code harness adapter.
#
# Every subcommand delegates to the script that already implements this
# behavior. Nothing is invented here. The point of this file is that run.sh
# stops knowing which harness it is talking to — not that anything about
# Claude ingest changes.
set -u

# cd -P, not plain cd. Logical resolution would succeed against a
# coincidental $TARGET/bin in the installed layout and silently land in the
# wrong directory; -P follows the adapters symlink physically first, so this
# resolves to the real bin/ regardless of what else exists alongside.
BIN=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)

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
    # A unique temp in the DESTINATION directory. A fixed "$2.tmp" is a shared
    # name: two invocations writing the same output would clobber or remove each
    # other's temp file and leave the result from the wrong one, or none.
    # A directory at the destination is refused. `mv -f "$t" "$2"` would move
    # the temp INSIDE it and return success, so the adapter would report a write
    # it never performed and leave a randomly-named file in the caller's
    # directory. The delegates used to reject this themselves, because a `>`
    # redirection to a directory fails; wrapping them removed that.
    [ ! -d "$2" ] || exit 1
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    cp "$1" "$t" 2>/dev/null || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    ;;

  project) # $1=session -> the session's real working directory
    [ -r "$1" ] || exit 1
    # jq, not grep: a cwd containing a quote or a backslash is JSON-escaped, and
    # a regex over the raw line either truncates at the escaped quote or hands
    # realpath a doubled backslash.
    cwd=$(jq -re 'select(.cwd != null) | .cwd' "$1" 2>/dev/null | head -1)
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

  # stats and slim delegate like everything else, but they cannot `exec`. Both
  # delegated scripts write the destination directly — slim-transcript.sh in two
  # steps, a `>` for the body and a `>>` for the footer — so an interruption
  # leaves a non-empty file with no footer, and the caller's `-s` check accepts
  # it and sends a truncated session to L1 as if it were whole.
  #
  # The atomicity belongs here rather than in those scripts: the contract is the
  # adapter's (docs/design/unify-harness-adapters-2026-08-23.md:131 requires it
  # of every subcommand that writes a file), and both scripts have callers
  # outside this seam. Same shape as normalize above — a unique temp in the
  # DESTINATION directory, renamed on success, removed on failure.
  #
  # DELIBERATELY NO SIGNAL TRAP, and this was measured rather than assumed. A
  # killed run leaves the temp behind, which is real but cosmetic: nothing reads
  # `*.tmp.*` — the findings glob is `*.json` and slim output is read by exact
  # path. Adding `trap 'rm -f "$t"' ... TERM` costs far more than it saves,
  # because bash defers a TRAPPED signal until the foreground child returns. The
  # delegate is that child, so the trap converts a prompt death into an adapter
  # that ignores SIGTERM for as long as the delegate runs — verified here: the
  # test below hung for 120s and left orphaned slim-transcript.sh processes
  # holding their input open. Being killed mid-flight is this pipeline's normal
  # failure, so trading a stale temp for a hung process is the wrong direction.
  # Backgrounding the delegate and killing it from the trap would work and is
  # five lines of signal plumbing in a file whose whole claim is that nothing is
  # invented here. Tracked instead.
  stats|slim)
    case "$cmd" in
      stats) delegate="$BIN/session-stats.sh" ;;
      slim)  delegate="$BIN/slim-transcript.sh" ;;
    esac
    [ ! -d "$2" ] || exit 1   # see the note on the first use above
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    "$delegate" "$1" "$t" || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    ;;

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
