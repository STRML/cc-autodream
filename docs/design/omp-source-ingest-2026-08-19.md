# OMP (oh-my-pi) as a second session source — 2026-08-19

Design doc for teaching autodream to triage Oh My Pi sessions alongside Claude Code
ones. Written before the wiring lands; the ingest scripts described in Phase 1 exist.

## Problem

autodream only sees `~/.claude*/projects`. Work done in OMP (`omp`, the Oh My Pi
coding harness) leaves no trace in the nightly report, so half the operator's day is
invisible to the thing whose whole job is noticing patterns in the operator's day.

## Non-goals

- Running the triage *with* `omp`. The engine stays `claude` (see "Engine" below).
- Deduping OMP sessions against Claude sessions. Different harnesses, different files;
  no overlap to resolve.
- Writing findings into OMP's own memory backend. Phase 4 at the earliest, and gated
  on the pilot protocol in issue #15.

## Three axes, only one of which actually forks

"Support OMP" reads like one feature and is three:

| Axis | Varies by source? | Work |
|---|---|---|
| **Engine** — which CLI performs triage | No | none |
| **Source** — which transcripts are ingested | Yes | root + deterministic normalizer |
| **Policy & sinks** — taxonomy, where fixes land | Yes, deeply | prompt fragment + sink adapter |

### Engine: stays `claude`

Verified 2026-08-19: a lean Claude worker (`--strict-mcp-config --settings
'{"disableAllHooks":true}' --tools Read Write`) reads an OMP session JSONL and pulls
`cwd` out of the tree header correctly, in ~10s on a small session.

`omp` itself is the wrong engine for this even though it is the harness under study.
It has no `--strict-mcp-config` equivalent: `--tools read,write` restricts built-ins
only, and every user-level MCP server still loads. Measured on this host: ~130 MCP
tool definitions ride into the worker's context and startup spends ~20s discovering
them, per worker, times fanout, nightly. A `--config` overlay with
`mcp.enableProjectConfig: false` does not help, because the servers are user-level.
The lean-isolation options that would fix it (scratch `PI_CONFIG_DIR` + injected
token, or a dedicated profile) all involve extracting credentials and were rejected.
Revisit only if OMP gains a real headless/lean switch.

So: **Claude reads, OMP is read.** The engine is already a single variable plus a
flag block in `dispatch_l1`; nothing to abstract.

### Source: OMP session files are trees

A Claude transcript is a flat list of turns. An OMP session file is not:

```
~/.omp/agent/sessions/<encoded-cwd>/<timestamp>_<sessionId>.jsonl
```

- Line 1 is a fixed-width 256-byte `type:"title"` slot; line 2 is a
  `type:"session"` header carrying `id`, `cwd`, `timestamp`. Legacy files start at the
  header.
- Every later entry carries `id` / `parentId`. Branching moves an in-memory leaf
  pointer and **rewrites nothing**, so abandoned branches stay in the file forever.
  The leaf pointer is not persisted; OMP's own loader falls back to the last entry in
  insertion order, and `buildSessionContext` walks `parentId` from there to the root.
- Entry types seen in practice: `message`, `custom` (tool-execution markers),
  `custom_message`, `model_change`, `thinking_level_change`, `title_change`,
  `credential_pin`, `session_init`, `compaction`, `reset_boundary`.
- `message` roles are `user`, `assistant`, `toolResult`. Content blocks are `text`,
  `thinking`, `toolCall`, `image`. Tool results are whole messages
  (`role:"toolResult"`, with `toolName`/`toolCallId`/`isError`), not blocks inside a
  user turn as in Claude.

**Reading such a file line-by-line attributes abandoned work to the session.** This is
the same class of hazard as `docs/investigations/session-branches-2026-07-20.md`,
which declined to dedup Claude transcripts because the base rate was zero and "which
branch is live" needed a length heuristic that could silently drop the live branch.
Here it inverts: the structure guarantees the hazard, and it is *decidable* — the leaf
walk is exact, no heuristic. That is why this gets normalized rather than tolerated.

### Policy & sinks: the part that genuinely forks

`prompts/SESSION_TRIAGE.md`'s taxonomy is Claude-specific throughout — it keys on
`skill_listing` attachments, `dangerouslyDisableSandbox` retries,
`.claude/settings.json` allowlists, and Claude tool names. `prompts/PROMPT.md` reads
`~/.claude/{skills,rules,projects}`, writes `MEMORY.md` pins, and `run.sh` then fires
`claude-memory gc`. None of that describes OMP, whose analogues are `rule://`
rulebooks, `--approval-mode`, skills under a different root, and mnemopi memory via
`retain`. Feeding OMP findings into the Claude sinks writes advice about the wrong
harness into the wrong store.

## Architecture

A **source profile** — five values per source, resolved per session:

| Field | claude | omp |
|---|---|---|
| `sessions_root` | `~/.claude*/projects` (existing `SESSION_ROOTS`) | `~/.omp/agent/sessions` |
| `normalizer` | none | `bin/linearize-omp-session.sh` |
| `self_prune` | existing first-user-turn regex | none needed (autodream never runs `omp`) |
| `policy_fragment` | current taxonomy | OMP taxonomy |
| `memory_sink` | `MEMORY.md` + `claude-memory gc` | none (report-only) |

Format is detected per session from the file's own structure, not from which root it
came from, so a moved or symlinked file cannot be misread.

### Enumeration is already solved

`SESSION_ROOTS` (colon-separated, added 2026-08-07 with `bin/root-probe.sh`) already
generalizes scanning to multiple roots. OMP needs its root to be an allowed entry;
`root-probe.sh` autodetects `$HOME/.claude*/projects` only, so the OMP root arrives
via config rather than autodetection, at least initially.

### Project identity comes from `cwd`, not the bucket

Bucket directory names are source-specific (`-Users-sean-sites` vs
`-sites`); `cwd` is the same real path in both. `run.sh` currently derives the
findings `project` field from the session path's parent directory. For mixed-source
aggregation that must key on `cwd` — from the Claude line field, or from the OMP
header, which the normalizer surfaces in its metadata record.

## Phase 1 — deterministic ingest (done, no model involved)

`bin/linearize-omp-session.sh` (new): walks `parentId` from the leaf to the root and
emits the live chain root-first, preceded by one `type:"autodream_meta"` JSON record
carrying `session_id`, `cwd`, `title`, `started_at`, and `entries`/`on_path`/`dropped`
counts.

- Metadata is a **real JSON object**, never a `#` banner: `slim-transcript.sh` runs one
  `jq` pass over the whole stream and falls back wholesale on any unparseable line, so
  a comment line would silently disable payload stripping downstream.
- `compaction` and `reset_boundary` entries are kept on the chain, not applied. Triage
  wants what happened, including pre-reset history that OMP's own full-transcript mode
  also retains. Only abandoned branches are dropped.
- **Fails closed** — nonzero exit, no output — on a non-OMP file, an unparseable line,
  a `parentId` cycle, or a dangling `parentId`. Callers MUST skip the session with a
  named error and MUST NOT fall back to the raw file: a dropped line can move the
  inferred leaf onto an abandoned branch, and confidently wrong triage is worse than a
  visible skip. Cost of strictness: a torn final line (crash, or a scan racing an
  append) loses that session for the night, reported rather than silent.

`bin/slim-transcript.sh` and `bin/session-stats.sh` become dual-schema, discriminating
on the entry's own `type`.

`session-stats.sh` is the subtle one and the reason this phase is not optional. The
noise gate in `dispatch_l1` reads `user_message_count` from the stats sidecar; OMP
counted with Claude's selectors yields **0**, so every OMP session would be stubbed
`below_noise_gate` without ever reaching a model — a feature that installs cleanly and
triages nothing. Its detection accepts both the raw `type:"session"` header and the
normalizer's `autodream_meta` record, because the linearized copy is the production
input and the raw header is gone by then.

OMP payloads are truncated to a head (default 200 chars) rather than erased: the first
line of a tool result (`Operation not permitted`) is the `sandbox_friction` signal, and
a `toolCall`'s command text is what makes a `tool_loop` recognisable as the same
command retried.

No `compliance_markers` in the OMP branch. They are a Claude-rules artifact,
`upstream/retire-compliance-markers` deletes them, and that branch merges *cleanly*
over an OMP copy of the counting logic — leaving retired telemetry alive for OMP only.
`PROMPT.md` already defaults the key to 0 when a findings record omits it.

**Acceptance:** unit + pipeline tests in `tests/run-all.sh`; real-corpus pass over the
host's OMP sessions with 0 rejections and plausible non-zero stats.

## Phase 2 — wiring (next)

1. `run.sh` resolves a format per session (structural detection, cheap `head`).
2. OMP sessions are normalized into `findings/<date>/<hash>.norm.jsonl` during
   enumeration, **before** `compute_session_stats`, so stats, the noise gate, slimming,
   and the L1 worker all read the live chain. `session_path` in the findings JSON is
   rewritten back to the original file, as slimming already does.
3. Normalization failure writes a findings record with an `error` key and skips the
   session. No raw-file fallback.
4. New `run-stats.txt` counters: `omp_sessions`, `omp_normalized`,
   `omp_normalization_failed`, `omp_branches_dropped`. A regression to "OMP silently
   not ingested" must be visible from the artifact, which is how every other
   source-level regression in this repo was caught.
5. `install.sh` links the new helper. Under launchd, helper resolution is
   `$SCRIPT_DIR` — the **installed** dir, because the plist invokes `$TARGET/run.sh`
   and `dirname "${BASH_SOURCE[0]}"` does not follow the symlink — then
   `$AUTODREAM_DIR`, which is the same dir. An unlinked helper is never found.
   (`run.sh` does walk its own symlink, but only for `RUNNER_COMMIT` provenance.)

**Conflict watch:** open PR #5 (`dy/triage-dream`) touches `bin/run.sh`,
`prompts/SESSION_TRIAGE.md`, `prompts/PROMPT.md` — the same files Phases 2 and 3 edit.
Phase 1 touches none of them, which is why it ships first.

## Phase 3 — source-aware L1 policy

Split `SESSION_TRIAGE.md` into a shared skeleton plus per-source taxonomy fragments.
Per issue #15, prompt edits sharing `SESSION_TRIAGE.md` + `PROMPT.md` go in **one
serial PR**, not split and not parallelized.

OMP-side categories worth naming, each needing a real transcript signal before it
earns a slot: approval-mode friction, rulebook misses (`rule://`), skill misses under
OMP's skill roots, MCP tool-surface bloat, subagent fan-out that should have been
inline.

## Phase 4 — sinks (deferred)

OMP findings are **report-only** until validated. This is not an interim hack; it is
issue #15's memory-write quarantine: unvalidated categories are ineligible for
`PROMPT.md`'s auto-memory-write gate (`confidence: high AND count >= 2 AND severity:
high` → 📌 pin) regardless of how L2 rates them, because pins are permanent by design.

Open question for later: whether OMP findings should eventually write to mnemopi via
`retain`, or to an `AGENTS.md`/`CLAUDE.md` context file OMP already reads. Not decided.

## Validating triage quality

Issue #15 is explicit that model-behavioral criteria cannot be discharged by the
deterministic suite — a scripted mock only proves the mock echoes what you wrote, and
suite assertions stop at L2 input. So: deterministic tests cover plumbing; **triage
quality is validated by a production pilot** — a week of nightly runs plus a manual
`jq` pass over the findings against the rendered reports.

## First real run (the immediate goal)

After Phase 2, force a rebuild for a date with real OMP activity and read the report.
What to check, in order:

1. `run-stats.txt`: `omp_sessions` non-zero, `omp_normalization_failed` zero,
   `gated` not suspiciously equal to the OMP session count (the noise-gate failure
   mode this design exists to prevent).
2. Per-session findings JSONs for OMP sessions: non-empty `tools_used`, plausible
   `turn_count`, `project` grouped by real path rather than split by bucket.
3. The report itself: do OMP sessions appear in the patterns, and is any finding
   about OMP work phrased in Claude terms (which would mean Phase 3's fragment is
   doing too little)?

### Precondition: this host's nightly is stale

Independent of OMP, the installed runner is 32 commits behind. `~/.claude/autodream`'s
symlinks point into a checkout parked on `feat/editor-agnostic-notify` (4 ahead, 32
behind `upstream/main`), which lacks `session-stats.sh`, `root-probe.sh`, and
`overlap-stats.sh` entirely. Evidence: the last three nights' `run-stats.txt` carry
only `sessions_triaged` among the modern keys — no `gated`, `runner_commit`,
`session_roots`, or `stats_sidecars_unparseable` — and `findings/2026-08-18/` holds 0
`*.stats.json` sidecars. Multi-root scanning, the noise gate, the oversized gate, and
runner provenance are all inert.

Re-point the install at a **clean** checkout at `upstream/main` (or at this branch) and
re-run `./install.sh`. Do not `git checkout main` in the existing checkout: it has an
uncommitted `prompts/SESSION_TRIAGE.md` change that would ride along. Then verify the
symlink targets and do one manual run before trusting a nightly.

## Risks

| Risk | Mitigation |
|---|---|
| Noise gate silently stubs every OMP session | Phase 1 dual-schema stats; `omp_*` counters in Phase 2 |
| Normalizer wrongly drops a live branch | Leaf walk is exact, not heuristic; fail closed; `dropped` count in metadata and run-stats |
| Fail-closed drops a session on a torn tail | Reported as an error finding, never silent |
| OMP findings phrased in Claude terms | Phase 3 fragment; caught by reading the first reports |
| Phase 2/3 collide with PR #5 | Phase 1 independent; rebase when #5 lands |
| Retired telemetry resurrected for OMP only | No `compliance_markers` in the OMP branch |
