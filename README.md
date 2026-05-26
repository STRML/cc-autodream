# cc-autodream

Nightly background process that reads your Claude Code session transcripts, finds recurring patterns (missed skills, sandbox friction, fabricated identifiers, skill misses, stop-projection, etc.), and produces an actionable daily report you can triage over morning coffee.

Two-layer pipeline:

- **Layer 1** — for each of yesterday's session JSONLs, a `claude --model haiku` worker reads the transcript and emits structured findings (JSON). Fanned out in parallel.
- **Layer 2** — a single `claude --model opus` aggregator reads all Layer-1 JSONs, ranks patterns by `count × severity`, writes a markdown report to `~/.claude/dreams/YYYY-MM-DD.md`, and (only for high-confidence/high-severity recurring findings) adds 📌-pinned entries to the relevant project's `MEMORY.md`.

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

## How it relates to Claude Code's built-in Auto Dream

Claude Code v5.3+ ships [a built-in Auto Dream feature](https://claudefa.st/blog/guide/mechanics/auto-dream) that *consolidates memory*: it prunes stale MEMORY.md entries, resolves contradictions, and reorganizes the index. It runs on a 24h + 5-session trigger.

cc-autodream solves a different problem. The built-in consolidator is a **memory garbage collector**; cc-autodream is a **signal extractor**. The two are designed to be symbiotic:

| | claudefa.st Auto Dream (built-in) | cc-simple-memory `gc-memory.sh` | **cc-autodream (this repo)** |
|---|---|---|---|
| Reads | MEMORY.md, transcripts (narrow) | MEMORY.md, ARCHIVE.md | full session JSONLs, fan-out across all of yesterday's sessions |
| Writes | MEMORY.md (prune/merge) | MEMORY.md (prune/merge), ARCHIVE.md | `dreams/YYYY-MM-DD.md`, MEMORY.md (📌 add) |
| Trigger | 24h + 5 sessions | every 10 extractions | nightly launchd at 03:15 |
| Cares about | hygiene | hygiene | discovery |
| Output for the human | none | none | daily report + interactive triage |

**The contract that makes them play nice**: cc-autodream pins everything it writes with the 📌 marker, and never deletes or rewrites a pinned entry. Both consolidators respect 📌 pins (will not prune them). So cc-autodream adds high-signal pins; the consolidators groom everything else around them.

If the built-in Auto Dream is active on your install (`/memory` will show `Auto-dream: on`), you don't need to disable it — cc-autodream's writes survive its passes. If `cc-simple-memory` is installed, same story.

If neither is installed, you have signal without hygiene. That's fine — your `MEMORY.md` files will grow until something prunes them, but cc-autodream itself caps additions at high-confidence/high-severity (typically 0–2 per day).

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
  │ Layer 2:                                     │
  │   claude --model opus --print                │
  │   with prompts/PROMPT.md                     │
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
prompts/
  SESSION_TRIAGE.md Layer 1 prompt (haiku worker, per-session JSON output schema)
  PROMPT.md         Layer 2 prompt (opus aggregator, report + pinned memory writes)
example/
  2026-05-25.md     a real overnight report
launchd/
  com.user.autodream.plist.example   schedule nightly at 03:15
install.sh          symlink scripts/prompts into ~/.claude/autodream/
```

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

## Costs

Per nightly run, very rough order-of-magnitude on a typical 50-session day:

- Layer 1: ~50 × haiku, each ~3-15k input tokens, ~500 output. With prompt caching: ~$0.20–0.50/day.
- Layer 2: 1 × opus, ~50–100k input (all findings) + 5–10k output. Without caching: ~$1–2/day.

Tune `FANOUT` down if you hit rate limits; the worker is idempotent (re-running skips sessions whose `*.json` already exists, non-zero).

## Caveats

- macOS only as written (uses `date -v-1d`, BSD `xargs`, BSD `find -newermt`). Linux port is trivial — swap `date -v-1d +%Y-%m-%d` for `date -d yesterday +%Y-%m-%d`.
- Requires `bypassPermissions` mode for both layers (workers need to Write into `findings/`, aggregator needs to Edit project MEMORY.md files). Don't run this in a shared environment.
- The report can be opinionated. The Layer-2 prompt instructs it to skip findings whose only proposed action is vague — but you should still read critically before acting on memory writes.

## License

MIT
