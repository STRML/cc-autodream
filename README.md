# cc-autodream

Nightly memory consolidation for Claude Code. While you sleep it reads yesterday's
session transcripts and leaves you one short report: the mistakes you keep making,
where you lost time, and what's worth remembering.

## Why

You have dozens of Claude Code sessions a week. The useful lessons — a wrong
assumption you made twice, a flag that always trips you up, a fix worth pinning to
memory — are buried in transcripts you'll never reread. Claude starts each session
fresh and rediscovers the same friction.

cc-autodream does the rereading for you. Every night it looks across **all** of
yesterday's sessions, ranks what recurs by frequency × severity (so you see the
patterns, not the one-offs), and writes a dated digest you can skim in a minute. The
highest-confidence, highest-severity findings get pinned into the relevant project's
`MEMORY.md`, so the next session already knows.

This is the cross-session view the built-in per-project auto-memory doesn't give you.
Anthropic's built-in auto-dream is a memory *janitor* — it grooms your `MEMORY.md`.
cc-autodream is a *signal extractor* — it reads full transcripts and tells you what
happened. They compose: cc-autodream adds the 📌 pins, the janitor grooms around them.

## What you get

A report at `~/.claude/dreams/YYYY-MM-DD.md`. See
[`example/2026-05-25.md`](example/2026-05-25.md) for a real one (60 sessions, seven
ranked patterns, five open questions). The shape:

```markdown
# Dream report — 2026-05-29   (21 sessions)

## Top patterns
1. **Editing files before reading them** ×6  ·  high
   Six sessions hit "File has not been read yet". Read-before-Edit isn't sticking.
   → Pin: always Read a file in-session before the first Edit.
2. **$() in Bash triggers permission prompts** ×4  ·  medium
3. **Assuming the host TZ is Pacific** ×2  ·  medium

## Upstream Claude Code changes
- v2.x.y added `--foo`; relevant to the rush project's deploy script.

## Open questions for the user
1. Add a Read-before-Edit reminder to the project CLAUDE.md?
```

Three ways you actually interact with it:

- **It runs unattended.** A launchd job fires overnight (with morning catch-up
  triggers in case the Mac was asleep). You do nothing.
- **It opens itself.** When a report lands, `notify.sh` writes its open questions to a
  text file and pops it open in your editor — so it's in front of you with morning
  coffee, not waiting to be discovered.
- **It has an interactive suggestion solver.** `review.sh` opens a Claude session
  preloaded with the report and walks the open questions one at a time — restate,
  recommend, then **approve / modify / skip / discuss** — executing the ones you
  approve and logging each decision back into the report.

## Install

```bash
git clone https://github.com/STRML/cc-autodream ~/git/cc-autodream
cd ~/git/cc-autodream
./install.sh
```

This symlinks `bin/*.sh` and `prompts/*.md` into `~/.claude/autodream/` and creates
`~/.claude/dreams/`. Because they're symlinks, editing the repo copy takes effect
immediately. Requires the `claude` CLI on PATH (override with `CLAUDE_BIN`).

Schedule the overnight run (macOS launchd):

```bash
cp launchd/com.user.autodream.plist.example ~/Library/LaunchAgents/com.user.autodream.plist
# edit the plist: replace REPLACE_WITH_USERNAME with your username, then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.autodream.plist
```

## Running it by hand

```bash
~/.claude/autodream/run.sh $(date -v-1d +%Y-%m-%d)       # process yesterday
AUTODREAM_FORCE=1 ~/.claude/autodream/run.sh 2026-05-29  # rebuild a date
~/.claude/autodream/review.sh                            # solve the latest report's questions
```

A full run usually takes more than 10 minutes. If you're kicking it off from
something that kills long jobs (a Claude Code background task, a flaky ssh session),
use `autodream-now.sh` — it hands the run to launchd, which has no time cap and keeps
going after you disconnect:

```bash
~/.claude/autodream/autodream-now.sh                    # yesterday, right now
~/.claude/autodream/autodream-now.sh 2026-05-29 --force # a specific date, rebuild
~/.claude/autodream/autodream-now.sh 2026-05-29 --watch # follow the log until the report lands
```

## How it works (short version)

Two layers: a cheap per-session pass (`haiku`) extracts structured findings from each
transcript, then a single smarter pass (`opus`) ranks them across the whole day and
writes the report. It also diffs the upstream Claude Code changelog over the day so
the report can flag releases that change how you work.

Everything lives on disk (findings JSON, the report, run logs, stats) and every step
is idempotent, so you can rerun any date. Configuration knobs are documented in
`bin/run.sh`'s header.

For the internals — data flow, file map, state layout, environment overrides, the
lean-query pattern, and the "don't eat your own tail" self-pollution defenses — see
**`codemaps/architecture.md`** and **`CLAUDE.md`**.

## Caveats

- macOS-only as written (BSD `date`, `launchd`, `osascript`/`subl`). The core pipeline
  is portable; the scheduling and notify bits are mac-specific.
- Runs in `bypassPermissions` mode (workers Write findings; the aggregator Edits
  project `MEMORY.md`). Don't run it in a shared environment.
- The first run clones `anthropics/claude-code` (small) for the changelog window; it
  degrades gracefully with no git/network.

## License

MIT — see LICENSE.
