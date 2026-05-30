# Codemap — architecture

Token-lean map of cc-autodream. See `CLAUDE.md` for the decisions and gotchas behind it.

## Data flow

```
launchd (com.samuelreed.autodream, several morning triggers)
      │
      ▼
bin/run.sh  TARGET_DATE
      │
      ├─ idempotency guard: report exists for date? → exit 0 (unless AUTODREAM_FORCE=1)
      │
      ├─ enumerate: find *.jsonl in [TARGET_DATE, NEXT_DATE)  → sessions.txt.raw
      │     └─ prune-self-sessions.sh --filter                → sessions.txt   (drops autodream's own)
      │
      ├─ L1 retry loop (AUTODREAM_L1_ROUNDS):
      │     dispatch_l1: xargs -P FANOUT → claude --print (haiku, lean flags) per session
      │       reads session .jsonl, writes findings/<date>/<sha>.json   (idempotent; .err on fail)
      │     l1_missing_count → wait_for_network → retry the still-missing
      │
      ├─ run-stats.txt          (self-audit telemetry)
      ├─ changelog_window()      → findings/<date>/changelog-window.md  (git log -p on claude-code CHANGELOG)
      │
      ├─ L2 retry loop (AUTODREAM_L2_ATTEMPTS):
      │     claude --print (opus, lean flags) with PROMPT.md
      │       reads all findings/<date>/*.json + changelog-window.md + run-stats.txt
      │       writes dreams/<date>.md; may edit project MEMORY.md (📌) + touched-projects.txt
      │
      ├─ notify.sh → open-questions inbox file (Sublime)
      └─ optional: claude-memory gc per touched project
```

## Files

| File | Role |
|---|---|
| `bin/run.sh` | orchestrator: guard, enumerate+filter, L1 retry loop, changelog, L2 retry loop, notify, gc |
| `bin/prune-self-sessions.sh` | self-session predicate (single source of truth): list / `--delete` / `--filter` |
| `bin/notify.sh` | extract "Open questions" → inbox file in Sublime |
| `bin/review.sh` | interactive morning triage (`claude --append-system-prompt <report>`) |
| `prompts/SESSION_TRIAGE.md` | L1 prompt: per-session JSON schema |
| `prompts/PROMPT.md` | L2 prompt: report sections incl. Upstream changes + Autodream self-audit, memory rules |
| `tests/run-all.sh` | integration tests vs `mock-claude.sh` (offline) |
| `tests/mock-claude.sh` | stand-in claude; modes: good / l1_incomplete / l1_flaky |
| `launchd/com.user.autodream.plist.example` | schedule (multi-trigger catch-up + pmset note) |
| `install.sh` | symlink scripts/prompts into `~/.claude/autodream/` |

## Key invariants

- L1 worker is **idempotent**: a session with a non-empty `<sha>.json` is skipped. Failures leave no JSON (retry target); deterministic errors (unreadable file) write a JSON (done).
- A `dreams/<date>.md` exists only after a successful L2 → it is the "done" signal for the idempotency guard.
- `prune-self-sessions.sh` matches only the FIRST user turn against autodream's own prompt framing → human sessions about autodream are not false positives.
- claude is always invoked with the lean flags + subscription auth; never `--bare`/`CLAUDE_CODE_SIMPLE` (breaks auth).
