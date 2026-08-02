# CLAUDE.md — cc-autodream

Operating notes for working on this repo. Read this before changing `bin/run.sh` or the prompts. The README is the user-facing pitch; this file is the stuff that bit us and the decisions behind the design, so future sessions don't re-derive them.

## What it is

A nightly two-layer pipeline that reads yesterday's Claude Code session transcripts and produces a ranked daily report plus a few pinned MEMORY.md entries.

- **Layer 1** (`prompts/SESSION_TRIAGE.md`, haiku, fanned out one per session): reads one transcript, writes one findings JSON.
- **Layer 2** (`prompts/PROMPT.md`, opus, single call): reads all findings JSONs, writes `dreams/YYYY-MM-DD.md`, optionally pins to project MEMORY.md.
- `bin/run.sh` orchestrates both layers and everything around them.

## Where state lives

All under `$AUTODREAM_DIR` (default `~/.claude/autodream/`) except the reports:

- `findings/YYYY-MM-DD/*.json` — Layer 1 output, one per session (keyed by a 12-char sha1 of the session path). `*.json.err` is a worker's stderr on failure.
- `findings/YYYY-MM-DD/sessions.txt` (+ `.raw`) — the enumerated session list (`.raw` is pre-self-filter).
- `findings/YYYY-MM-DD/changelog-window.md` — upstream changelog diff for the date (see below).
- `findings/YYYY-MM-DD/run-stats.txt` — self-audit telemetry the aggregator reads.
- `findings/YYYY-MM-DD/operator-notes.md` — every capture surface's notes merged into the one file L2 reads. `vault-notes-manifest.txt` alongside it lists the inbox files that went into it.
- `findings/YYYY-MM-DD/x-bookmarks.md` — unread X bookmarks for the "Ideas from bookmarks" section, plus `x-bookmarks-manifest.txt` of their ids. `x-bookmarks/seen.jsonl` holds the persistent read state.
- `findings/YYYY-MM-DD/touched-projects.txt` — sidecar listing projects whose MEMORY.md L2 edited (drives the optional `claude-memory gc`).
- `cache/claude-code/` — persistent clone of `anthropics/claude-code` for the changelog.
- `logs/run-YYYY-MM-DD.log` — full run log (run.sh tees here). `logs/launchd.{out,err}.log` — launchd's capture.
- `dreams/YYYY-MM-DD.md` (default `~/.claude/dreams/`) — the final report.

Scripts/prompts are symlinked into `~/.claude/autodream/` by `install.sh`, so editing the repo copy takes effect immediately. The installed launchd job is `com.samuelreed.autodream` (not the `com.user.*` example label).

`install.sh` also installs that scheduled job by default (unless `--no-schedule`): it generates the plist with auto-detected label/PATH/dirs (same detection as `autodream-now.sh` — reuses an existing `*autodream*` plist's label if present, else synthesizes `com.<user>.autodream`), then `bootout`+`bootstrap`s it. `RunAtLoad` is false, so install *arms* the schedule without firing a run; the four morning triggers (03:15/06:15/09:15/12:15) match the example plist. It does not run `pmset` (sudo) — it only prints the `pmset repeat wake` recommendation. The `launchd/*.example` file is kept as a hand-editable fallback.

## How claude is invoked — the lean-query pattern (do not use `--bare`)

Both layers call `claude --print` with a composed set of minimal-footprint flags borrowed from claude-cells `internal/claude/query.go`. The point: strip per-call bloat (hooks, skills, MCP, CLAUDE.md auto-load) while KEEPING subscription/OAuth auth.

```
--no-session-persistence            # see self-pollution below
--tools Read Write                  # L1; L2 uses: Glob Read Write Edit
--disable-slash-commands            # no skills
--strict-mcp-config                 # no MCP servers
--settings '{"disableAllHooks":true}'   # no hooks (incl. the big SessionStart injection)
```
plus env `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1`, and `--permission-mode bypassPermissions` so workers can write.

**Do NOT switch to `--bare` or `CLAUDE_CODE_SIMPLE=1`.** Verified (2026-05) with a control on this host: plain `claude --print` authenticates, but both `--bare` and `CLAUDE_CODE_SIMPLE=1` return "Not logged in". They disable OAuth/keychain auth and require `ANTHROPIC_API_KEY` (or an apiKeyHelper), and `--bare`'s toolset is only Bash+Edit (no Read/Write/Glob). The composed flags above give the same minimal footprint without breaking auth or the file tools. (claude-cells uses simple mode only inside containers, where creds are a mounted `.credentials.json` file, not the macOS keychain.)

## Self-pollution (the eating-its-own-tail bug)

Every `claude --print` call used to persist its own session JSONL into `~/.claude/projects/-Users-<you>/`. So a run that triaged ~190 sessions left ~190 worker transcripts, and the NEXT night's run enumerated those as "sessions" to triage. On a real day, ~90% of the corpus was autodream looking at itself (215 enumerated vs. 21 real on 2026-05-29).

Three defenses, all in place:
1. **Root cause**: `--no-session-persistence` on every call. New runs leave no transcript.
2. **Enumeration filter**: after `find`, the session list is piped through `bin/prune-self-sessions.sh --filter`, which drops any session whose first user turn is one of autodream's own inlined prompts (markers: `Session transcript to analyze (literal absolute path)`, `Findings directory to aggregate (literal absolute path)`, legacy `SESSION_PATH=` / `FINDINGS_DIR=`). This catches transcripts left by runs predating the fix.
3. **Backlog cleanup**: `bin/prune-self-sessions.sh` (dry-run lists, `--delete` removes). `prune-self-sessions.sh` is the single source of truth for the "is this ours?" predicate; run.sh resolves it relative to itself (`BASH_SOURCE`).

The predicate is anchored to the FIRST user message so a human session that merely *discusses* autodream is not a false positive.

### The AI-title stub vector (second-order self-pollution)

`--no-session-persistence` suppresses the full transcript but NOT Claude Code's **AI-title generation**: a fire-and-forget background call that writes a one-line `{"type":"ai-title",...}` stub into the launch cwd's project bucket. Because workers ran from `cd "$HOME"`, those stubs landed in the real `-Users-<you>` bucket and polluted session history / `search-sessions` — 339 of them accumulated 2026-05-25…06-02 (titles like "Analyze Claude session findings", "Aggregate daily findings into report"). Whether a stub lands is version/timing-dependent (the `--print` process sometimes exits before the async write flushes — current builds often drop it, older ones flushed it), so the fix must not assume the binary's current behavior.

Two defenses:
1. **cwd isolation + wipe (run.sh)**: both layers now launch from `$AUTODREAM_DIR/work` (`WORK_DIR`), not `$HOME`. Claude maps cwd → `~/.claude/projects/<cwd with / and . → ->`, so any stub lands in the isolated `WORK_BUCKET` instead of the real bucket. `clean_work_bucket` (`rm -rf "$WORK_BUCKET"`) runs before L1 and after L2, so stubs never accumulate. Workers read/write only by absolute path, so cwd is functionally irrelevant — L1 cd's inside the worker subshell; L2 cd's inside a subshell so the change does not leak into the notify/GC steps. **Watch the apostrophes**: the L1 worker body is a single-quoted `bash -c '...'`, so a `'` in a comment there silently breaks quoting (it still passes `bash -n`).
2. **Pruner title predicate (`is_self_title`)**: catches orphan stubs in the real bucket left by runs predating defense 1. Gated on (a) NO user turn anywhere in the file — a real session keeps its title alongside its conversation turns, so it is never a title-only orphan and is never matched — AND (b) the title paraphrases our L1/L2 prompts (session triage → findings, aggregate findings → report). Tuned against the real backlog: spares terminal-tab-title stubs and unrelated headless orphans (e.g. "GCU Rush firmware development").

## Sleep resilience

The overnight failure mode: launchd fires at the scheduled time on a brief wake, the Mac sleeps in and out during the run, workers lose the network and fail (we saw 104/215 fail, L2 exit 1, no report).

launchd facts: `StartCalendarInterval` is anacron-like (runs once on the next wake if asleep at the trigger), NOT vanilla cron. But launchd does not WAKE the Mac (use `pmset repeat wake` for that), and it does nothing about sleep DURING a run.

run.sh handles it with:
- **L1 retry loop** (`dispatch_l1` + `l1_missing_count`): re-dispatches only the sessions still missing a findings JSON, up to `AUTODREAM_L1_ROUNDS` (5), calling `wait_for_network` between rounds. The worker is idempotent, so retries are cheap.
- **L2 retry loop**: retries the aggregator up to `AUTODREAM_L2_ATTEMPTS` (3) until `$REPORT_PATH` is non-empty.
- **Idempotency guard**: at the top of `run()`, if a report already exists for the date it exits in a second (`AUTODREAM_FORCE=1` to rebuild). This is what makes multiple launchd catch-up triggers safe.
- The plist example schedules several morning triggers (03:15/06:15/09:15/12:15) so a failed-overnight date gets retried on later wakes; the guard no-ops the rest.

`net_up` checks reachability of `api.anthropic.com` (any HTTP code beats `000`). Disable the wait with `AUTODREAM_NETCHECK=0` (tests set this).

## Upstream changelog window

`changelog_window()` clones/pulls `anthropics/claude-code` into `cache/claude-code` and runs `git log -p` on `CHANGELOG.md` over `[TARGET_DATE, NEXT_DATE)` (real commit dates; the raw CHANGELOG has no dates, the git history does). The inserted lines go to `changelog-window.md`, which L2 reads for the "Upstream Claude Code changes" report section. Any git failure writes a note and never aborts the run. There is no remote `git blame`; that is why we keep a persistent local clone.

## Operator notes: one file for the prompt, many surfaces for the human

`PROMPT.md` reads exactly one notes path, `findings/<date>/operator-notes.md`, and `bin/vault-notes.sh` writes it by merging every capture surface. Adding a surface is a change to that script and never to the prompt. Today there are two:

- `~/.claude/autodream/notes.md`, appended by `autodream-note.sh`. Terminal-only, unchanged, still the right thing for an agent leaving itself a note mid-session.
- `$AUTODREAM_VAULT_DIR/inbox/*.md`, one file per note. This is the surface that gets used away from the keyboard — Obsidian mobile, Shortcuts, a share sheet, anything that writes a file into a synced folder. Optional YAML frontmatter `expires: YYYY-MM-DD`; expired notes are dropped at collect time so the prompt keeps exactly one expiry format to parse (the `- [added] (expires DATE)` lines).

Consumed inbox files move to `processed/<date>/` and the report is copied to `reports/<date>.md` for phone reading. Both steps are gated on a **non-empty** report, deliberately stricter than the `-f` check that encloses them: archiving a note the aggregator never read destroys the only copy, silently and unrecoverably. The manifest exists for the same reason — `collect` records which files it read and `archive` moves only those, so a note written during the ten minutes a run takes is not swallowed unread.

The vault lives in iCloud, which evicts file contents under storage pressure and leaves a `.<name>.icloud` placeholder. 03:15 is exactly when nothing has touched the vault for hours, so `materialize()` calls `brctl download` and waits for the placeholders to clear (`AUTODREAM_ICLOUD_WAIT`, default 30s). A note still dataless after the wait is written into `operator-notes.md` as `UNREADABLE` and left in the inbox rather than skipped — a note the user wrote and we could not read is worth saying out loud.

### run.sh sources the config now

It didn't until this feature; only `review.sh` did, which was fine while every key was review-only and stopped being fine the moment `AUTODREAM_VAULT_DIR` had to reach the nightly run. Two details in that block are load-bearing and both were caught by tests rather than by reading:

- **`set -a` around the source.** The helper scripts are separate processes, so a config key that stays an unexported shell variable reaches nothing. Without it the config parses fine and the feature silently does not happen.
- **The `export -p` snapshot replayed after.** The config uses plain `KEY=value`, so a bare `.` lets the file clobber a variable the caller deliberately exported. Tests set env; a run invoked with an explicit `AUTODREAM_VAULT_DIR=` to disable the vault has to actually disable it.

`AUTODREAM_DIR` is resolved before the source and therefore cannot be set from the config. That is not an oversight — it names the file's own location.

## X bookmarks as idea fuel

`bin/x-bookmarks.sh` fetches recent bookmarks into `findings/<date>/x-bookmarks.md`; `PROMPT.md`'s "Ideas from bookmarks" section crosses them against the day's findings. The section's whole value is the intersection, so the prompt is explicit that a bookmark with no connection to this run gets left out and "none connected" is a correct answer — otherwise the model manufactures links and the section becomes a reading list the user already read.

The official API is not an option: `GET /2/users/:id/bookmarks` has never been on the free tier and needs Basic at $200/mo (checked 2026-08-02). So it reads X's internal web GraphQL endpoint with cookies pasted once into `$AUTODREAM_DIR/x-credentials`. The queryId in that endpoint's path rotates on X deploys, which is why the script scrapes it from the live JS bundle and caches it rather than hardcoding one.

Two invariants keep this from ever costing a night's report: the script always exits 0, and it always writes its output file — including a "not configured" stub and a `# x-bookmarks: fetch failed — <reason>` header. `mark-read` runs only after a non-empty report, same reasoning as the note archive above: a bookmark stamped read by a run that produced nothing is a bookmark the user never gets an idea from.

## Self-audit

run.sh writes `run-stats.txt` (raw/excluded/triaged counts, L1 rounds/done/missing/err, elapsed). PROMPT.md's "Autodream self-audit" section reads it and is told to flag self-pollution regressions (excluded count climbing), pipeline-capacity problems (oversized transcripts that blow the token budget), retry/sleep health, and to propose concrete cc-autodream source fixes since the user authors the tool. It proposes; it does not edit cc-autodream source.

### Degraded measurements must say so, not read as zero

Two counters exist only to keep a broken measurement from looking like a real result, and any new stat should follow the same rule. `overlap_measured: yes|no` (#26) marks whether the cross-session overlap pass actually ran. `stats_sidecars_unparseable: N` (#27) counts sessions whose `*.stats.json` sidecar was missing, empty, or had no numeric `transcript_bytes`.

The sidecar counter is deliberately one number rather than a flag per stat: a broken sidecar degrades several counters at once (the noise gate and the oversized gate both read the same file), so the failure is counted once and PROMPT.md caveats the affected keys. The oversized loop walks `sessions.txt` rather than the `*.stats.json` glob — a sidecar that was never written is absent from the glob, and the session it belonged to used to vanish from `oversized_total` silently. Sizes for those sessions fall back to `wc -c` on the transcript itself, which is exactly what `transcript_bytes` holds anyway, so the #12 gate keeps a truthful number instead of a clamped 0.

The noise gate's own sidecar read still biases to triage on an unparseable sidecar and that stays — the cost is one wasted model call. What was missing there was never the behavior, only the signal.

### Which code actually ran (`runner_commit`)

`install.sh` symlinks `~/.claude/autodream/*.sh` straight at the repo working tree, so the nightly executes whatever is checked out at 03:15. A tree behind origin runs old code even though the fix is merged and the PR is green. This has cost data twice: the 2026-07-24 `overlap-stats.sh` dangle, and a tree stuck on a local commit from 2026-07-20 to 2026-07-24 that wrote four nights of `run-stats.txt` with no `oversized_*` / `gated` / `overlap_*` keys at all.

`run-stats.txt` therefore carries `runner_commit` + `runner_dirty` (#29). The diagnostic that matters: a `run-stats.txt` that is *missing keys*, rather than holding suspicious values, means an old runner — not a stat that didn't apply. Both times it took a reflog dig to establish that.

`bin/oversized-gate.sh` exists because of the same incident. The #12 gate is a trailing-window judgment but `run.sh` records one night at a time, so a stretch of old-runner nights used to be unrecoverable. It recomputes the window from the `*.stats.json` sidecars and findings JSONs still on disk, which survive independently of whether the runner knew how to count them. Artifacts only, no model calls, safe to re-run. It refuses to call an empty window a measured 0%, and quotes a rule-of-three upper bound so a clean run isn't read as stronger evidence than the sample supports.

## Running / rerunning a date

```
~/.claude/autodream/run.sh 2026-05-29        # process a date
AUTODREAM_FORCE=1 ~/.claude/autodream/run.sh 2026-05-29   # rebuild despite an existing report
```
To reprocess cleanly (e.g. after the corpus changed), delete that date's findings dir AND report first, then run; otherwise idempotency reuses old findings and the guard skips. Env knobs are documented in `run.sh`'s header and the README.

### Running on-demand without the 10-min cap (`autodream-now.sh`)

A full run routinely exceeds 10 minutes, so launching `run.sh` from a foreground/background context that has a time cap (a Claude Code background Bash task, an ssh session that may drop) gets it killed mid-flight. `bin/autodream-now.sh` sidesteps this by handing the run to **launchd**, which owns the process — no time cap, survives the caller disconnecting.

```
~/.claude/autodream/autodream-now.sh                  # yesterday, now
~/.claude/autodream/autodream-now.sh 2026-05-29 --force   # specific date, rebuild
~/.claude/autodream/autodream-now.sh 2026-05-29 --watch   # tail run log until report lands
~/.claude/autodream/autodream-now.sh 2026-05-29 --dry-run # print plist + commands, run nothing
```

How it works: it writes a transient one-shot LaunchAgent (`<base-label>.ondemand`, `RunAtLoad`) into `$AUTODREAM_DIR`, `bootout`s any prior instance, then `bootstrap`s it so launchd runs `run.sh <date>` once and the job exits. `RunAtLoad` is the *only* trigger — it deliberately does not also `kickstart`, or a fast run (e.g. the idempotency no-op) would fire twice. It never touches the scheduled nightly job. Everything is auto-detected: it resolves its own symlink to find `run.sh`, picks the scheduled plist whose `ProgramArguments` reference `run.sh` (not the sibling `*-review` job) to borrow its label namespace, and detects uid + the `claude`/`git` dirs for the agent's PATH — so it is not specific to one user or host. The default date is computed with plain `date -v-1d`, exactly like run.sh (no TZ override). `--force` maps to `AUTODREAM_FORCE=1`; the caller's `AUTODREAM_DIR`/`DREAMS_DIR` are passed through. Progress is in `$AUTODREAM_DIR/logs/run-<date>.log`; the agent's own stdout/stderr go to `logs/ondemand.{out,err}.log`.

When you (the agent) need to kick off a run, prefer this over a background Bash task — fire it, then poll `dreams/<date>.md` instead of holding a long task open.

## Tests

`tests/run-all.sh` drives the real `run.sh` against `tests/mock-claude.sh` (no network, no model). Mock modes: `good` (default), `l1_incomplete` (worker writes nothing), `l1_flaky` (fails first dispatch per session, succeeds on retry). The suite forces `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0` and a low `AUTODREAM_L1_ROUNDS` so it never sleeps or hits the network. macOS only (BSD `date`/`touch`). Run it after any run.sh/prompt change.

The suite pins `AUTODREAM_CONFIG` into its sandbox now that `run.sh` sources the config. Without that pin, a developer whose real config points `AUTODREAM_VAULT_DIR` at a live Obsidian vault would have the test suite writing notes and reports into it. `MOCK_MODE=l2_fail` makes the aggregator write nothing and exit 1, which is how the "don't archive an unread note" guard is tested; pair it with `AUTODREAM_L2_ATTEMPTS=1` so the test doesn't sit through the retry loop.

`tests/x-bookmarks.sh` covers the bookmark fetcher with `curl` shimmed and the queryId cache pre-seeded, so nothing touches X. The bundle-scraping walk is untested on purpose — it runs against a live third party and a fake proves nothing about it. Everything downstream of the HTTP call is pinned hard, because that is where both development bugs lived: the emit came out oldest-first (it trusted file order, which is only chronological within one run), and `mark-read` silently no-opped on every row (`$ids | index(.id)` rebinds `.` to the array before `.id` is read, so it indexed an array with a string). Neither showed up in a smoke test and both would have quietly wasted the feature.

`tests/review-skip.sh` covers `bin/review.sh`'s skip/launch decision against fixture reports, with an inline mock claude that just touches a marker file — if the marker exists, review.sh reached `exec claude`. It pins `AUTODREAM_CONFIG` to a nonexistent path so the host's own config (`AUTODREAM_TRIAGE_SURFACE=cmux`) can't leak in and spawn a real workspace mid-test. Run it after any review.sh change, and after changing PROMPT.md's Open-questions marker contract.

## Gotchas (host environment)

- The user's shell rewrites `grep` to `rtk grep`, which rejects some flags (`-h`); prefer `tail`/`rg`-style invocations when scripting against logs interactively.
- The Claude Code sandbox denies writes under `~/.claude/` (including `rm` of symlinks/findings); those operations need the sandbox disabled.
- Subagent transcripts live in `projects/.../<session>/subagents/agent-*.jsonl` and ARE legitimate sessions to triage; they are not self-pollution.
- `claude --print` worker calls run from cwd `$HOME`, so any transcript they (used to) leave landed in the `-Users-<you>` project bucket.
