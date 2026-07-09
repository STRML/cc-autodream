# Editor-agnostic notify.sh

**Date:** 2026-07-09
**Status:** Approved

## Problem

`bin/notify.sh` hardcodes Sublime Text in two places:

1. The notification click action: `-execute "open -a 'Sublime Text' '$OUT'"`
2. The direct open at the end of the script: `"$SUBL" "$OUT"`, backed by an
   auto-probe chain (`$HOME/bin/subl` → PATH → the app bundle's `subl`)

Users without Sublime get a click action that fails and a "subl not found"
log line. The tool is distributed (README, LICENSE, install.sh), so the
open behavior must work for any user out of the box.

## Design

### New env var: `AUTODREAM_OPEN`

A shell command that opens the inbox file. Examples: `subl`, `code -g`,
`open -a Obsidian`. It is a shell snippet, not a bare binary path — it is
run through `sh -c`, so flags and multi-word commands work.

Resolution order:

1. `$AUTODREAM_OPEN` if set
2. `$SUBL` if set — deprecated back-compat alias; internally treated as
   `AUTODREAM_OPEN="$SUBL"`
3. Default: `open` — macOS opens the file with the user's default `.md` app

The Sublime auto-probe chain is deleted. Users who want Sublime set
`AUTODREAM_OPEN=subl`.

### Call sites

Both call sites use the same resolved command, `$OPEN_CMD`:

- **Notification click:** `-execute "$OPEN_CMD '$OUT'"`. Default click
  action becomes `open '<inbox file>'`.
- **Direct open:** `sh -c "$OPEN_CMD \"\$1\"" _ "$OUT"` so multi-word
  commands word-split correctly while the filename stays safely quoted.
  A failure logs and continues — the banner remains the reliable signal,
  as today.

Log lines name the resolved command instead of "Sublime".

### Docs and tests

- `README.md` — replace the `subl` mention (line ~138); document
  `AUTODREAM_OPEN`
- `codemaps/architecture.md` — `SUBL` env-var row becomes `AUTODREAM_OPEN`,
  with `SUBL` noted as deprecated
- `tests/run-all.sh` — switch to `AUTODREAM_OPEN=/usr/bin/true`; keep one
  invocation on `SUBL=/usr/bin/true` to cover the deprecated alias
- `CHANGELOG.md` entry

## Out of scope

Cross-platform support (e.g. Linux `xdg-open`). The README declares the
tool macOS-only; a port can set `AUTODREAM_OPEN=xdg-open`.

## Error handling

- Resolved command fails at direct-open time: log and continue (exit 0
  path unchanged).
- `AUTODREAM_OPEN` set to something bogus: the `sh -c` invocation fails,
  logged, run continues. No validation up front — same trust level as the
  existing `SUBL` override.
