# cc-autodream

Nightly background process that reads your Claude Code session transcripts, finds recurring patterns (missed skills, sandbox friction, fabricated identifiers, skill misses, stop-projection, etc.), and produces an actionable daily report you can triage over morning coffee.

Two-layer pipeline:

- **Layer 1** — for each of yesterday's session JSONLs, a `claude --model haiku` worker reads the transcript and emits structured findings (JSON). Fanned out in parallel.
- **Layer 2** — a single `claude --model opus` aggregator reads all Layer-1 JSONs, ranks patterns by `count × severity`, writes a markdown report to `~/.claude/dreams/YYYY-MM-DD.md`, and (only for high-confidence/high-severity recurring findings) adds 📌-pinned entries to the relevant project's `MEMORY.md`. `run.sh` also pulls `anthropics/claude-code` into a persistent cache and diffs `CHANGELOG.md` over the report's date window (by real commit date); the aggregator reads that diff and surfaces an "Upstream Claude Code changes" section flagging releases that should change how we work in sessions or affect active projects.

Then in the morning: `review.sh` opens an interactive Claude session preloaded with the report and walks you through the open questions one at a time.

## Example

See [`example/2026-05-25.md`](example/2026-05-25.md) — a real overnight report covering 60 sessions, surfacing seven ranked patterns (oversized-JSONL Read loops, repeated `commit-and-verify` skill misses, `dangerouslyDisableSandbox` overuse, missing `ASSUMPTIONS` blocks, etc.), and ending with five open questions for the human.

## Install

```bash
git clone https://github.com/STRML/cc-autodream ~/git/cc-autodream
cd ~/git/cc-autodream
./install.sh
```

That symlinks `bin/*.sh` and `prompts/*.md` into `~/.claude/autodream/`, creates `~/.claude/dreams/`, and leaves `findings/`, `inbox/`, `logs/` for runtime state.

Verify:

```bash
~/.claude/autodream/run.sh $(date -v-1d +%Y-%m-%d)   # process yesterday
~/.claude/autodream/review.sh                         # triage the latest report
```

Schedule (macOS launchd, runs nightly at 03:15):

```bash
cp launchd/com.user.autodream.plist.example ~/Library/LaunchAgents/com.user.autodream.plist
# edit the plist: replace REPLACE_WITH_USERNAME
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.autodream.plist
```

Requires `claude` CLI on PATH (default expected at `$HOME/.local/bin/claude` — override with `CLAUDE_BIN`).

## FAQ

### Why does this exist? Doesn't Claude Code have auto-dream built in?

Anthropic does ship an `autoDream` service in Claude Code — the [leaked source](https://github.com/codeaashu/claude-code) puts it at `src/services/autoDream/` with a four-phase consolidation prompt (Orient → Gather Signal → Consolidate → Prune-and-Index) and the same 200-line / 25 KB MEMORY.md index cap (`MAX_ENTRYPOINT_LINES = 200`, `MAX_ENTRYPOINT_BYTES = 25_000`). But that built-in feature is a **memory janitor**: it reads your `MEMORY.md` plus narrow transcript slices and rewrites the index to prune stale entries, resolve contradictions, and merge near-duplicates. It does not produce a daily report. It does not read all of yesterday's sessions end-to-end. It does not surface "you missed the commit-and-verify skill three times yesterday."

cc-autodream is a **signal extractor**, not a janitor. It fans out a Layer-1 worker per session JSONL, mines the full transcripts for recurring patterns (missed skills, sandbox friction, tool loops, fabricated identifiers, missed `ASSUMPTIONS` blocks, stop-projection), ranks them by `count × severity`, and writes a markdown report you triage with morning coffee. Plus 📌-pinned MEMORY.md entries for the small subset of findings that meet high-confidence / high-severity / recurring bars.

Different inputs, different outputs, different role.

| | Anthropic auto-dream (built-in) | claude-dream (community port) | cc-simple-memory | **cc-autodream (this repo)** |
|---|---|---|---|---|
| Input | MEMORY.md + topic files + narrow transcript slices | MEMORY.md + topic files | MEMORY.md + ARCHIVE.md | full session JSONLs (every session, fanned out) |
| Output | rewritten MEMORY.md index | rewritten MEMORY.md index | pruned MEMORY.md + ARCHIVE.md cold storage | daily report + 📌 pins into MEMORY.md |
| Trigger | `stopHooks` (24h + 5 sessions, gated by GrowthBook flag `tengu_onyx_plover`) | manual `/dream` | every N extractions or `claude-memory gc` | nightly launchd at 03:15 |
| Role | janitor | janitor | janitor | **discovery telescope** |
| Output for the human | none | none | none | daily markdown report + interactive triage |

### Is this useful outside of (or alongside) the built-in auto-dream?

Yes, for two independent reasons.

1. **Most users don't have auto-dream active yet.** It's behind a GrowthBook rollout flag — the code is in the binary, the behavior is off for almost everyone. As of `claude 2.1.150` on my machine, `/memory` reports "isn't available in this environment" and no consolidation happens. You can check yours with `/memory` inside a session; if the toggle is unavailable, you're not in the rollout.

2. **Even when auto-dream lights up, it solves a different problem.** It will tidy your MEMORY.md. It will not tell you that yesterday's `web-app` session bypassed the sandbox on 79% of Bash calls and that the `commit-and-verify` skill was skipped three times across two projects. That's cc-autodream's job. The two compose: cc-autodream adds the 📌 pins, auto-dream grooms everything around them.

### If I don't have auto-dream yet, does cc-autodream do the same thing?

No — and you probably want one of each.

- **For memory hygiene** (the actual auto-dream role), pair cc-autodream with one of:
  - [`jl-cmd/claude-dream`](https://github.com/jl-cmd/claude-dream) — a community port of Anthropic's auto-memory consolidation contract as a manual `/dream` slash command. Same 200-line / 25 KB / 150-char-per-entry caps. Same `{user, feedback, project, reference}` frontmatter taxonomy. Lightweight; no scheduled run.
  - [`STRML/cc-simple-memory`](https://github.com/STRML/cc-simple-memory) — a heavier-weight memory plugin with extraction hooks plus `claude-memory gc` (Opus-driven prune + ARCHIVE.md cold storage). If you want consolidation to happen automatically every N extractions rather than on demand.
  - Or wait for Anthropic to flip your `tengu_onyx_plover` flag.
- **For cross-session signal extraction**, run cc-autodream. There is no built-in equivalent and (as far as I've looked) no other community tool that reads full session JSONLs and produces a ranked daily report.

### How does cc-autodream stay out of the janitor's way?

By respecting the same contract Anthropic's auto-dream enforces, so its pins survive any consolidator's grooming pass:

- **Every entry cc-autodream writes is 📌-pinned.** All four tools above treat 📌 as "don't prune."
- **Each MEMORY.md line stays ≤150 characters.** That's the implicit index-entry budget in the leaked `consolidationPrompt.ts` ("an index, not a dump — each entry should be one line under ~150 characters"). Topic-file bodies go in sibling files.
- **Topic files use the four-type frontmatter** (`user` / `feedback` / `project` / `reference`). cc-autodream's signal almost always maps to `type: feedback`.
- **cc-autodream never deletes or rewrites an existing 📌 entry.** Hygiene is the janitor's job; we only add.
- **Optional GC handoff**: if `claude-memory` is on PATH, the nightly runner triggers `claude-memory gc` for each project where it added a pin so the consolidator can resettle around the new entries. Disable with `AUTODREAM_GC=0`. If `claude-memory` isn't installed, the step is a silent no-op.

## Architecture

```
~/.claude/projects/*/sessions/*.jsonl                  (Claude Code session transcripts)
                  │
                  ▼
       find -newermt yesterday
                  │
                  ▼
  ┌──────────────────────────────────────────────┐
  │ Layer 1: xargs -P 8                          │
  │   claude --model haiku --print               │
  │   with prompts/SESSION_TRIAGE.md             │
  │   → findings/YYYY-MM-DD/<sha>.json           │
  └──────────────────────────────────────────────┘
                  │
                  ▼
  ┌──────────────────────────────────────────────┐
  │ Changelog: git pull anthropics/claude-code   │
  │   diff CHANGELOG.md over [date, date+1)      │
  │   → findings/<date>/changelog-window.md      │
  └──────────────────────────────────────────────┘
                  │
                  ▼
  ┌──────────────────────────────────────────────┐
  │ Layer 2:                                     │
  │   claude --model opus --print                │
  │   with prompts/PROMPT.md                     │
  │   reads findings + changelog-window.md       │
  │   → dreams/YYYY-MM-DD.md                     │
  │   → projects/*/memory/MEMORY.md (📌 only)    │
  └──────────────────────────────────────────────┘
                  │
                  ▼
       notify.sh extracts the
       "Open questions" section
       and pops it open in Sublime
                  │
                  ▼ (morning)
  ┌──────────────────────────────────────────────┐
  │ review.sh                                    │
  │   claude --append-system-prompt <report>     │
  │   "go" → walks you through Q&A interactively │
  └──────────────────────────────────────────────┘
```

## Files

```
bin/
  run.sh            nightly entry point — both layers
  review.sh         interactive morning triage
  notify.sh         extracts open questions → Sublime
  prune-self-sessions.sh  find/--delete autodream's own worker transcripts; --filter excludes them from triage
prompts/
  SESSION_TRIAGE.md Layer 1 prompt (haiku worker, per-session JSON output schema)
  PROMPT.md         Layer 2 prompt (opus aggregator, report + pinned memory writes)
tests/
  run-all.sh        integration tests (drives run.sh against a mock claude)
  mock-claude.sh    stand-in claude binary used by the tests
example/
  2026-05-25.md     a real overnight report
launchd/
  com.user.autodream.plist.example   schedule nightly at 03:15
install.sh          symlink scripts/prompts into ~/.claude/autodream/
```

## Tests

```
tests/run-all.sh
```

Integration tests that run the real `bin/run.sh` end-to-end against a mock
`claude` binary (`tests/mock-claude.sh`) and fixture session files — no network,
no model calls. They cover the happy path, unreadable-session validation,
incomplete worker runs, idempotent re-runs, the no-sessions stub, a
regression guard on the literal-path prompt framing (no `KEY=value` / `$VAR`
shapes that a worker could mistakenly `$`-expand), and the upstream-changelog
window (driven against a local fixture git remote, so it stays offline and
asserts that in-window releases are captured and out-of-window ones excluded).
macOS only (BSD `date`/`touch`).

## Environment overrides

All optional; defaults work for a vanilla Claude Code install on macOS.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_BIN` | `$HOME/.local/bin/claude` | path to `claude` CLI |
| `PROJECTS_DIR` | `$HOME/.claude/projects` | where Claude Code stores session JSONLs |
| `AUTODREAM_DIR` | `$HOME/.claude/autodream` | scripts + runtime state |
| `DREAMS_DIR` | `$HOME/.claude/dreams` | where final reports are written |
| `FANOUT` | `8` | Layer 1 parallelism |
| `SUBL` | `$HOME/bin/subl` then PATH | Sublime Text CLI for `notify.sh` |
| `AUTODREAM_CHANGELOG` | `1` | set `0` to skip the upstream-changelog check |
| `CLAUDE_CODE_REPO` | `$AUTODREAM_DIR/cache/claude-code` | persistent cache for the `anthropics/claude-code` clone |
| `CHANGELOG_REMOTE` | `https://github.com/anthropics/claude-code.git` | git remote to clone/pull for the changelog |

## Lean workers, and not eating your own tail

Each layer shells out to `claude --print`, and two things matter for cost and correctness:

**No self-pollution.** A `claude --print` call persists its own session JSONL into `~/.claude/projects/`. Left unchecked, last night's ~190 worker transcripts become tonight's "sessions to triage" — ~90% of the corpus is autodream looking at itself. Both layers now pass `--no-session-persistence`, so new runs leave no transcript. For transcripts left by older runs, the enumeration step pipes the session list through `prune-self-sessions.sh --filter` (which recognizes autodream's own inlined prompts) so they're never triaged. Clean up the backlog on disk with `prune-self-sessions.sh` (dry-run) then `--delete`.

**Minimal footprint, subscription auth preserved.** The workers don't need your hooks, skills, MCP servers, or `CLAUDE.md`. Rather than `--bare` / `CLAUDE_CODE_SIMPLE` — which on a keychain host disable OAuth and demand an `ANTHROPIC_API_KEY` — each call composes the individual lean flags (the `claude-cells` `internal/claude/query.go` pattern), which keep subscription auth:

```
--no-session-persistence            # no transcript
--tools Read Write                  # L1 (L2: Glob Read Write Edit) — only what's needed
--disable-slash-commands            # no skills
--strict-mcp-config                 # no MCP servers
--settings '{"disableAllHooks":true}'   # no hooks (incl. SessionStart injection)
```
plus env `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1`.

## Costs

Per nightly run, very rough order-of-magnitude on a typical 50-session day (after self-session exclusion):

- Layer 1: ~50 × haiku, each ~3-15k input tokens, ~500 output. With prompt caching: ~$0.20–0.50/day.
- Layer 2: 1 × opus, ~50–100k input (all findings) + 5–10k output. Without caching: ~$1–2/day.

Tune `FANOUT` down if you hit rate limits; the worker is idempotent (re-running skips sessions whose `*.json` already exists, non-zero).

## Caveats

- macOS only as written (uses `date -v-1d`, BSD `xargs`, BSD `find -newermt`). Linux port is trivial — swap `date -v-1d +%Y-%m-%d` for `date -d yesterday +%Y-%m-%d`.
- Requires `bypassPermissions` mode for both layers (workers need to Write into `findings/`, aggregator needs to Edit project MEMORY.md files). Don't run this in a shared environment.
- The report can be opinionated. The Layer-2 prompt instructs it to skip findings whose only proposed action is vague — but you should still read critically before acting on memory writes.
- The upstream-changelog step needs `git` and network at run time to clone/pull `anthropics/claude-code`. It degrades gracefully — a clone/pull failure (or `AUTODREAM_CHANGELOG=0`) just writes a note into `changelog-window.md` and the run continues. The cache persists between runs, so steady-state cost is one delta fetch.

## License

MIT
