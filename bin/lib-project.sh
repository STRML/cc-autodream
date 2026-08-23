#!/bin/bash
# Canonical project identity, shared by every harness adapter.
#
# Claude derives a project bucket name from the session's cwd by mapping path
# separators AND dots AND underscores to dashes, on the symlink-resolved
# physical path. Verified against real buckets on this host:
#
#   /Users/<u>/.claude                      -> -Users-<u>--claude
#   /private/var/folders/c2/29g..z_4tv..gn  -> -private-var-folders-c2-29g..z-4tv..gn
#
# Both of those break an encoder that maps only `/`, and they break it
# silently: the record still carries a cwd, so nothing counts it as
# unreconciled — the project just quietly splits in two.
#
# This lives in one place because every adapter must produce the SAME key for
# the same real directory. That is what makes one project out of two harnesses'
# work, and it is why this design has no reconciliation pass at all. Deriving
# the key once, here, at triage time removes the failure rather than fixing it.
#
# macOS resolution matters too: Claude records the physical path, so a session
# in /tmp/foo is stored under -private-tmp-foo, while a harness that reports an
# unresolved cwd would produce -tmp-foo and group as a different project.

# Encode an already-absolute, already-resolved path into a bucket name.
encode_project() { # $1=absolute path -> encoded bucket name on stdout
  printf '%s' "$1" | tr '/._' '---'
}

# Resolve a path to its physical location, then encode it. Fails loudly rather
# than encoding something unresolved: a wrong project key splits a group, and a
# silent split is precisely what this function exists to prevent.
canonical_project() { # $1=path -> encoded name on stdout, or exit 1 with nothing
  local real
  real=$(realpath "$1" 2>/dev/null) || return 1
  [ -n "$real" ] || return 1
  encode_project "$real"
}
