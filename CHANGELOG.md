# Changelog

All notable changes to cc-autodream. Format loosely follows Keep a Changelog.

## [Unreleased] — 2026-05-30

### Added
- **Upstream changelog awareness.** `run.sh` clones/pulls `anthropics/claude-code` into a persistent cache and diffs `CHANGELOG.md` over the run's date window (by real commit date, since the raw changelog carries no dates but the git history does). Layer 2 reads the result and writes an "Upstream Claude Code changes" report section flagging releases that change how we work or affect active projects. Degrades gracefully with no git/network. Knobs: `AUTODREAM_CHANGELOG`, `CLAUDE_CODE_REPO`, `CHANGELOG_REMOTE`.
- **Self-pollution prevention.** Both layers now pass `--no-session-persistence`, so `claude --print` workers no longer leave their own transcripts in `~/.claude/projects/` for the next run to re-triage (this had been ~90% of the corpus). New `bin/prune-self-sessions.sh` is the single source of truth for the "is this autodream's own session?" predicate: lists them, `--delete` purges the backlog, `--filter` excludes them. `run.sh` enumeration pipes through `--filter` so pre-fix transcripts are never triaged.
- **Sleep-resilient retry.** `run.sh` retries L1 over only the still-missing sessions across network/sleep gaps (`AUTODREAM_L1_ROUNDS`, `wait_for_network`), retries L2 until a report lands (`AUTODREAM_L2_ATTEMPTS`), and short-circuits via an idempotency guard when a report already exists (`AUTODREAM_FORCE=1` to rebuild). The launchd example now schedules several morning catch-up triggers and documents a `pmset` scheduled wake.
- **Autodream self-audit.** `run.sh` writes `run-stats.txt` (sessions found/excluded/triaged, L1 rounds/done/missing/err, elapsed). A new PROMPT.md "Autodream self-audit" section turns the lens on the pipeline: it flags self-pollution regressions, pipeline-capacity issues (oversized transcripts), and retry/sleep health, and proposes concrete cc-autodream source fixes since the user authors the tool.
- **Docs.** `CLAUDE.md` (decisions, state layout, gotchas) and `codemaps/architecture.md` (data flow + file map), so the analysis behind this work is not re-derived next session.

### Changed
- **Lean-query invocation.** Both layers compose minimal-footprint flags from claude-cells `internal/claude/query.go` (`--tools <only-needed> --disable-slash-commands --strict-mcp-config --settings '{"disableAllHooks":true}'` + env `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`, etc.), cutting per-call tokens by dropping hooks/skills/MCP/CLAUDE.md while keeping subscription OAuth auth.

### Notes
- **Do not use `--bare` / `CLAUDE_CODE_SIMPLE`.** Verified they disable OAuth/keychain auth (require an API key) and limit tools to Bash+Edit; the composed flags above are the supported path for subscription users.
- Tests grew from 6 to 12 cases (changelog window, prune helper, self-session exclusion, L1 flaky retry, idempotency guard, self-audit stats); all offline against the mock claude.
