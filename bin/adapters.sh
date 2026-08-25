#!/bin/bash
# Adapter loading and dispatch.
#
# THE MANIFEST IS DATA. It is JSON, read with jq, and never sourced. A sourced
# manifest executes arbitrary code as the user, and a plugin format whose parser
# is bash is an injection surface the moment a third-party adapter is a
# reasonable idea. $HOME is the only interpolation, done by substitution rather
# than evaluation, so a manifest holding backticks yields literal backticks.
#
# IDENTITY IS THE DIRECTORY BASENAME, never a manifest field, because dispatch
# builds a command path from it. A manifest that could name its own directory
# could reintroduce exactly the path construction that JSON parsing was adopted
# to remove. The manifest's `name` must AGREE with the basename — a mismatch is
# a load-time refusal rather than a silently preferred value, because two
# disagreeing identities is the state where a later reader picks the wrong one.
#
# A BASENAME CHECK IS NOT CONTAINMENT. `adapters/evil` may be a symlink pointing
# anywhere on the filesystem, so each directory is resolved with realpath and
# refused unless it is still under the adapters root.
#
# REJECTIONS GO TO A FILE, NOT A VARIABLE. `adapters_list` is almost always
# called as `$(adapters_list)`, and a variable assigned inside a command
# substitution never comes back to the caller — the same trap that cost this
# repo the cookie-expiry remediation text in vault-notes.sh, where FAIL_REASON
# was set inside nested $(...) and died with the subshell. A file crosses the
# boundary; a variable does not.
set -u

# Where refusals are recorded. Callers may point this at a findings dir so the
# count reaches run-stats.txt; it defaults beside the adapters root.
adapters_reject_log() {
  if [ -n "${ADAPTERS_REJECT_LOG:-}" ]; then printf '%s' "$ADAPTERS_REJECT_LOG"; return 0; fi
  printf '%s' "$(adapters_root)/.rejected"
}

# Two layouts have to work, and assuming only one is how the first version of
# this change shipped a silently broken install. In the REPO, bin/ and adapters/
# are siblings. Under the INSTALL, install.sh symlinks everything flat into
# ~/.claude/autodream, so adapters/ sits beside adapters.sh rather than one level
# up. Check the flat layout first: the nightly runs from the installed copy, so
# that is the expensive one to get wrong.
adapters_root() {
  if [ -n "${ADAPTERS_ROOT:-}" ]; then printf '%s' "$ADAPTERS_ROOT"; return 0; fi
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -d "$here/adapters" ]; then printf '%s' "$here/adapters"; return 0; fi
  printf '%s' "$(cd "$here/.." && pwd)/adapters"
}

# Comma-separated list of refused directory names, readable after a
# $(adapters_list) call because it is backed by a file.
adapters_rejected() {
  local log; log=$(adapters_reject_log)
  [ -f "$log" ] || return 0
  sort -u "$log" | tr '\n' ',' | sed 's/,$//'
}

_adapter_reject() { # $1=name
  local log; log=$(adapters_reject_log)
  printf '%s\n' "$1" >> "$log" 2>/dev/null || true
}

# A directory is a usable adapter iff every one of these holds. Ordered cheapest
# first, but each is load-bearing rather than defensive: see the header.
_adapter_ok() { # $1=basename
  local root dir real realroot name
  root=$(adapters_root)
  dir="$root/$1"

  # A leading underscore marks a test-only adapter. Excluded silently, because
  # it is a deliberate exclusion rather than a refusal worth counting.
  case "$1" in _*) return 1 ;; esac

  # Safe identifier: lowercase start, then lowercase/digit/underscore/dash only.
  # No separators, so the name cannot walk out of the adapters root on its own.
  case "$1" in
    [a-z]*) : ;;
    *) _adapter_reject "$1"; return 1 ;;
  esac
  case "$1" in *[!a-z0-9_-]*) _adapter_reject "$1"; return 1 ;; esac

  # Containment. A symlinked adapter dir passes every check above and still
  # points anywhere, so resolve both sides and require the prefix.
  real=$(realpath "$dir" 2>/dev/null)     || { _adapter_reject "$1"; return 1; }
  realroot=$(realpath "$root" 2>/dev/null) || { _adapter_reject "$1"; return 1; }
  case "$real" in
    "$realroot"/*) : ;;
    *) _adapter_reject "$1"; return 1 ;;
  esac

  [ -f "$dir/manifest.json" ] && [ -x "$dir/adapter.sh" ] || { _adapter_reject "$1"; return 1; }

  # jq -e fails on unparseable JSON, so a malformed manifest is refused whole
  # rather than partially trusted.
  name=$(jq -re '.name // empty' "$dir/manifest.json" 2>/dev/null) || { _adapter_reject "$1"; return 1; }
  [ "$name" = "$1" ] || { _adapter_reject "$1"; return 1; }
  return 0
}

adapters_list() {
  local root d n
  root=$(adapters_root)
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    _adapter_ok "$n" && printf '%s\n' "$n"
  done
  return 0
}

adapter_manifest_get() { # $1=name $2=jq path -> value on stdout
  local root v
  root=$(adapters_root)
  v=$(jq -re "${2} // empty" "$root/$1/manifest.json" 2>/dev/null) || return 1
  # $HOME by substitution, never evaluation.
  printf '%s' "${v//\$HOME/$HOME}"
}

adapter_run() { # $1=name $2=subcommand [args...]
  local root name
  root=$(adapters_root); name="$1"; shift
  "$root/$name/adapter.sh" "$@"
}
