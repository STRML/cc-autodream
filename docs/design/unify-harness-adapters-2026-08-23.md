# Design: one autodream, many harnesses

Date: 2026-08-23
Status: APPROVED by panel (executor, auditor, antigravity)
Baselines read for this document: `cc-autodream` at `0dffef5` (branch `retire-compliance-markers`), `omp-autodream` at `387e7bc` (branch `main`), `seanperkins/autodream-merge` at `c4ebdfc`.

## Problem

Three repos do one job.

- `STRML/cc-autodream` — the nightly for Claude Code.
- `STRML/omp-autodream` — the nightly for Oh My Pi, ported 2026-08-17.
- `seanperkins/autodream-merge` — a consumer that merges the two repos' findings dirs into one report.

The port was a copy. Measured divergence between the two runners, counting changed lines against combined line count:

| File | Divergence |
| --- | --- |
| `bin/vault-notes.sh` | 0% |
| `bin/x-bookmarks.sh` | 0% |
| `bin/oversized-gate.sh` | 0% |
| `bin/cookie-cadence.sh` | 0% |
| `bin/slim-transcript.sh` | 0% |
| `bin/overlap-stats.sh` | 0% |
| `bin/autodream-now.sh` | 0% (4 lines) |
| `prompts/SESSION_TRIAGE.md` | 1% (4 lines) |
| `bin/notify.sh` | 4% |
| `bin/session-stats.sh` | 9% |
| `bin/run.sh` | 10% |
| `bin/root-probe.sh` | 11% |
| `prompts/PROMPT.md` | 15% |
| `bin/prune-self-sessions.sh` | 19% |
| `install.sh` | 32% |
| `bin/review.sh` | 32% |

Six files are byte-identical. Every fix now has to be ported by hand, and a fix that lands in one repo and not the other is invisible until a night goes wrong.

The split also costs the reader. A pattern with evidence in both harnesses lands in two reports, and neither can rank it. `autodream-merge` exists to recover that signal, and it works, but it recovers the signal by re-deriving facts that were available at triage time and are cheaper to get right there.

## Goals

1. One repo, one nightly, one report.
2. Harness support is a directory, not a fork. Adding `codex` or `pi` later means writing one directory and touching no shared code.
3. Findings carry which harness produced them, because the remedy differs per harness.
4. No regression against today's cc-autodream behavior on a single-harness host.

## Non-goals

- Running one engine against another harness's sessions. Each harness's sessions are triaged by that harness's engine.
- Preserving per-harness reports. One report covers the union.
- Migrating historical findings dirs. Old dirs stay readable by `oversized-gate.sh` and `cookie-cadence.sh`, which recompute from artifacts. This constrains the session-list format and the hash formula, both of which those tools recompute; see "Session list".

## Decisions

Five decisions were settled before this document was written.

1. **Repo identity.** Rename `STRML/cc-autodream` to `STRML/autodream`. GitHub redirects the old URL, so existing clones and the live `~/.claude/autodream` symlinks keep working. Archive `omp-autodream` and `autodream-merge` with pointers.
2. **Aggregation shape.** L1 fans out across every enabled adapter into one findings dir. One L2 pass over the union, always. A single-harness day is the degenerate case where N is 1. There is no conditional merge path and no merge phase.
3. **Memory writes.** L2 becomes a pure function: findings in, report and proposed pins out, no filesystem writes. Each adapter owns its own memory store and applies the pins routed to it.
4. **Adapter shape.** A directory holding declarative facts, code, and prompt text.
5. **Rollout.** One branch, one cutover. A replay harness against an archived corpus stands in for phased verification.

Decision 5 was taken against the recommendation in this document's discussion, and the review panel independently recommended against it as well (the Architect seat asked for a three-day side-by-side into a parallel `dreams-v2/`). The recorded objection: the first real integration test runs unattended at 03:15, which is the shape of both failures the repo's `CLAUDE.md` documents at length — the 2026-08-02 `tee` SIGPIPE and the four nights of `run-stats.txt` written by a stale runner. The decision stands as the author's call. The replay harness in the test section is the agreed mitigation, and it is explicitly not a substitute for operational verification.

## Architecture

### Layout

```
autodream/
  bin/
    run.sh              orchestrator, harness-agnostic
    adapters.sh         loader and dispatcher                    [new]
    lib-project.sh      canonical project encoding               [new]
    preflight.sh        shared-dependency and engine checks      [new]
    session-stats.sh    dispatches parsing to the adapter
    prune-self-sessions.sh, root-probe.sh, slim-transcript.sh
    vault-notes.sh, x-bookmarks.sh, notify.sh, autodream-now.sh,
    oversized-gate.sh, cookie-cadence.sh, overlap-stats.sh, review.sh
  adapters/
    claude/   manifest.json  adapter.sh  facts.md  install.sh
    omp/      manifest.json  adapter.sh  facts.md  linearize.sh  install.sh
    _fixture/ manifest.json  adapter.sh  facts.md                [test-only]
  prompts/
    SESSION_TRIAGE.md   one file
    PROMPT.md           one file, source-aware, stdout-only
  tests/
```

Nine `bin/` scripts move across unchanged. Six of those are already byte-identical between the repos, so there is no merge to perform on them.

### The adapter contract

Each adapter is a directory with three required files and one optional one.

**`manifest.json`** — declarative, read with `jq`. It is JSON rather than sourced shell because a sourced manifest executes arbitrary code as the user, and a plugin format whose parser is `bash` is an injection surface the moment a third-party adapter is a reasonable idea. `jq` is already a hard dependency.

```json
{
  "name": "omp",
  "session_roots_default": ["$HOME/.omp/agent/sessions"],
  "session_glob": "*.jsonl",
  "engine_bin": "omp",
  "engine_flags_l1": ["--allow-home", "-p", "--permission-mode", "bypassPermissions"],
  "l1_model": "runinfra/deepseek-v4-flash",
  "writes_memory": false
}
```

`$HOME` is the only interpolation performed, by explicit substitution rather than by evaluation.

**Adapter identity is the directory basename, not the manifest.** Dispatch builds `adapters/<name>/adapter.sh` from the directory it enumerated, never from a manifest field, so a malformed or hostile manifest cannot reintroduce the command-path construction that JSON parsing was adopted to remove. A directory whose basename is not a safe identifier — matching `[a-z][a-z0-9_-]*`, with no separators and no leading dot — is refused at load with a named counter. The basename check alone is not containment: `adapters/evil` may be a symlink pointing anywhere. Each adapter directory is therefore resolved with `realpath` and refused unless it is still under the adapters root, which closes the escape a name-only check leaves open. `name` inside the manifest must equal the basename; a mismatch is a load-time error rather than a silently preferred value, because two disagreeing identities is exactly the state where a later reader picks the wrong one.

**L2 engine configuration is orchestrator-level, not adapter-level.** An earlier draft put an `l2_eligible` flag in the manifest; that conflates a harness's ingest capability with the orchestrator's choice of reasoning engine, and it is a regression against today's behavior, where `run.sh` already resolves `AUTODREAM_L2_MODEL` as a global knob (`bin/run.sh:1085-1092`). The unified runner keeps `AUTODREAM_L2_BIN` and `AUTODREAM_L2_MODEL` global. L2 may therefore run on an engine that is not an enabled adapter at all.

**`adapter.sh`** — one subcommand per place the two runners diverge today. The list was derived from the diff above, not from anticipated need.

| Subcommand | Contract | Absorbs |
| --- | --- | --- |
| `enumerate <root> <date>` | prints absolute session paths, one per line | `root-probe.sh` 11% |
| `normalize <in> <out>` | writes a triage-ready transcript to `<out>`; nonzero exit means skip this session | new |
| `project <session>` | prints the session's real working directory, absolute and symlink-resolved | new |
| `stats <session>` | prints the stats sidecar JSON | `session-stats.sh` 9% |
| `slim <in> <out>` | writes a size-reduced transcript to `<out>` | `slim-transcript.sh` |
| `is-self <session>` | exit 0 if this is one of autodream's own worker transcripts | `prune-self-sessions.sh` 19% |
| `skills-inventory` | prints the active skill list, one per line | `omp-autodream/bin/skills-inventory.sh` |
| `apply-pin <json>` | writes one pin; `0` wrote, `10` declined (reason on stdout), any other code is a failure | new |
| `memory-root <session>` | prints the absolute, canonical memory-store root that owns this session; empty output is legal **only** for a `writes_memory: false` adapter | new |
| `gc <memory-root> <project>` | resettles this harness's consolidator around newly written pins; only ever called for a triple whose `apply-pin` returned `0`, so a no-store adapter never receives it | `bin/run.sh:1290-1310` |

**Every subcommand has a named skip path and atomic output.** A subcommand that writes a file writes to `<out>.tmp` in the destination directory and renames on success; a nonzero exit leaves no `<out>` and removes any partial `<out>.tmp`. A nonzero exit from `project`, `stats`, or `slim` skips that session with its own counter, exactly as `normalize` does — the earlier draft specified failure handling only for `normalize`, which left three subcommands with undefined behavior on a partial write.

The runner also re-checks readability immediately before each read rather than once at the top. `bin/run.sh:553` checks a session is readable and `bin/run.sh:588` sizes it later; a file deleted between those two produces an empty `wc` result and still reaches the worker.

`normalize` fails closed. An OMP session file is an append-only tree where branching moves a leaf pointer rather than rewriting the file, so the file physically retains work the user backed out of. Reading it raw attributes discarded work to the user. A non-OMP file, an unparseable line, a `parentId` cycle, or a dangling parent each exit nonzero with no output, and the caller skips that session with a named error. For the claude adapter, `normalize` is a copy.

**`linearize.sh` is new work, not a port.** An earlier draft said it could be brought across from `omp-autodream`. It cannot: that repo has no such file, tracked or untracked, and its runner feeds L1 the raw session (`omp-autodream/bin/run.sh:623`, `readpath="$session"`). The implementation exists only in closed PR `STRML/cc-autodream#47` and must be rewritten here with its own fixtures. This has a second consequence worth stating plainly: **`omp-autodream` is triaging OMP session trees whole today**, abandoned branches included. That is a live defect in shipped code and is filed separately.

**`facts.md`** — the remedy vocabulary for this harness, concatenated into the L2 prompt under a `## source: <name>` heading. This exists because the same finding category needs a different remedy per harness:

| Finding | Claude Code remedy | OMP remedy |
| --- | --- | --- |
| `sandbox_friction` | a `permissions.allow` line in `settings.json` | OMP has no `settings.json`; a different mechanism |
| `missed_skill` | a trigger phrase in a `SKILL.md` | OMP skill roots plus `config.yml` `ignoredSkills`; built-ins are compiled into the binary and are not on disk |
| `memory_miss` | a pinned entry in `MEMORY.md` | a rule, a hook, or a doc note; mnemopi autolearn owns memory |
| `compliance_failure` | cite `~/.claude/CLAUDE.md` | cite OMP's rule surface |

Without this, L2 proposes editing a `settings.json` that does not exist for the session it is talking about. Roughly half of today's 15% `PROMPT.md` divergence is exactly this text.

**`install.sh`** — optional. The core installer handles the orchestrator: symlinks, base directories, the launchd job. Anything harness-specific is an `adapters/<name>/install.sh` hook the core script invokes when present. This is why the two `install.sh` files sit at 32% divergence; a monolithic installer that understands every harness's dependencies would re-create the fork inside one file.

### Session list

**`sessions.txt` keeps its existing shape: one bare absolute path per line.** An earlier draft proposed `<source>\t<path>`, which is wrong. Four separate consumers derive an artifact key or a filesystem path from the whole line:

- `bin/run.sh:468` — `h=$(printf "%s" "$s" | shasum -a 1 | cut -c1-12)`
- `bin/run.sh:540` — the same hash inside the `xargs -P … -I {}` worker
- `bin/oversized-gate.sh:73` — recomputes that hash from `sessions.txt`
- `bin/oversized-gate.sh:81` — `size=$(wc -c < "$session")` when the sidecar is degraded

A tab in the line corrupts the hash in all four and makes the size read fail, which the gate then counts as unmeasurable even though the transcript exists. It would also silently invalidate every archived findings dir, since the gate recomputes hashes from artifacts that survive independently of the runner.

Source is carried in a sidecar instead: `findings/<date>/sessions-source.txt`, one `<hash>\t<source>` line per session. The hash stays `sha1(bare path)`, so every existing consumer and every archived dir keeps working untouched.

**Transport and the line-based artifact are two different things, and an earlier draft conflated them.** The in-memory fan-out is NUL-delimited (`find -print0`, `xargs -0`, `read -r -d ''`), which fixes the split at `bin/run.sh:348` and `bin/run.sh:538` where a newline in a path currently becomes two sessions. But `sessions.txt` stays line-based, because `oversized-gate.sh` and every archived findings dir depend on that shape. A line-based file cannot represent a path containing a newline, so NUL transport alone does not save it.

**Only the newline is rejected.** A path containing a newline is dropped at enumeration with `sessions_rejected_path`. Tabs are accepted, and an acceptance fixture pins that: an earlier draft rejected them too, on a rationale left over from the discarded `<source>\t<path>` format. Verified against the actual consumers — `IFS= read -r` performs no word splitting, so a tab survives the read intact; `printf '%s' "$s" | shasum` covers it, so the artifact hash stays distinct; and `sessions-source.txt` is `<hash>\t<source>` and never holds a path, so its own tab separator is never ambiguous. Rejecting a valid path on a rationale that does not hold is a silent data loss dressed as safety.

The rejected path is logged with control characters escaped. A newline written raw into the log would forge additional log lines, which is a small thing until the forged line is the one someone reads.

NUL transport still earns its place — it removes the whole class of word-splitting bugs on the paths that *are* accepted, including spaces, tabs and glob characters.

**Cross-adapter collision.** Two adapters enumerating the same absolute path produce the same `<hash>.json`, and the second worker overwrites the first source's findings. Changing the hash formula to include the source would fix it and break every archived dir, so instead the union step detects a path claimed by more than one adapter, logs both adapter names, keeps the first, and counts `sessions_duplicate_path`. In practice this means two adapters are pointed at one store, which is a misconfiguration worth seeing rather than resolving silently.

**Hash collision between distinct paths.** The artifact key is a 12-character truncation of SHA-1, so two different paths can in principle land on one filename, and the failure is a silent overwrite of one session's findings by another. At 48 bits the birthday bound sits far above any real corpus, so this is not expected to fire; the check is included because it costs one associative lookup during the union and the failure it prevents is invisible. The union records hash to path, and a hash arriving with a different path than the one already recorded is rejected with `sessions_hash_collision`, both paths logged. Unlike the duplicate-path case there is no sensible resolution, so both sessions are skipped rather than one being chosen arbitrarily.

### Project identity

`autodream-merge` reconciles project identity after merging, by re-encoding an OMP session's header `cwd` into Claude's bucket name (`bin/merge-reports.sh:162`). That pass is best-effort by construction, and its encoder is wrong: it maps `/` only, while Claude also maps `.` and `_`. Verified against real buckets on the target host:

```
/Users/samuelreed/.claude
  merge-reports -> -Users-samuelreed-.claude    bucket exists? no
  correct       -> -Users-samuelreed--claude    bucket exists? yes

/private/var/folders/c2/29g2958n6t92169z_4tvmsb80000gn/T/tmp-2wxKWV0A91
  merge-reports -> ...29g2958n6t92169z_4tvmsb80000gn...   bucket exists? no
  correct       -> ...29g2958n6t92169z-4tvmsb80000gn...   bucket exists? yes
```

A wrong encoding splits a project silently: the record has a `cwd`, so it is never counted as unreconciled.

This design removes the failure rather than fixing the encoder. `adapter project <session>` returns the session's real working directory, absolute and symlink-resolved. One shared `lib-project.sh` encodes it once, mapping `/`, `.`, and `_` to `-`. Every harness produces the same key for the same directory at L1 time. There is no reconciliation phase, so there is no `records_unreconciled_project` counter, because there is nothing to fail.

Symlink resolution matters on macOS: Claude records the physical path, so a session in `/tmp/foo` becomes `-private-tmp-foo`, while OMP's header `cwd` is unresolved.

## Nightly flow

0. **Preflight.** `bin/preflight.sh` verifies the shared dependencies the runner assumes today — `jq` (`bin/run.sh:360`), `shasum` (`bin/run.sh:468`), `python3` (`bin/run.sh:924`) — plus `realpath`, and the configured L2 engine binary. `realpath` is new and it is security-critical rather than convenient: it resolves adapter directories for containment and canonicalizes `cwd` for project identity. A host that reaches adapter loading without it would fall back to weaker containment, which is the failure the check exists to prevent, so its absence is a hard stop and never a degraded path. A missing `shasum` is the dangerous one: the hash assignment silently yields an empty string and every session targets the same findings filename. Each missing dependency is a named hard failure with its own telemetry key, not a degraded run.
1. `run.sh` resolves enabled adapters from `AUTODREAM_ADAPTERS` (default: every `adapters/*/manifest.json` except `_fixture`), then verifies each adapter's `engine_bin`. An adapter whose engine is absent is disabled with a counter; this is not fatal. The L2 engine check at step 0 is separate and *is* fatal, because without it no report is possible.
2. Per adapter, `enumerate` produces a session list. The union is written to `sessions.txt` (bare paths) plus `sessions-source.txt` (hash to source), with `sessions.txt.raw` kept pre-filter as today.
3. Per session: `is-self` filter, then `normalize`, then `stats` sidecar, then the noise gate, then `slim`, then the L1 worker on that adapter's engine and model.
4. The L1 model emits **triage payload only**. `run.sh` validates that JSON and then envelopes it, atomically, with provenance the runner already resolved: the session path, the adapter `source`, the raw `cwd` from `adapter project`, `encode(cwd)` as `project`, and the `memory_root` from `adapter memory-root`. The result is one `<hash>.json` per session in one findings dir.

   **The model never supplies its own provenance.** Those five fields later authorize pin routing and memory placement, so a model that could write them could name a source and project it never touched — and L1 reads a transcript, which is attacker-adjacent input on any day someone pastes something interesting into a session. Runner-stamped provenance makes the authorization set a property of what the runner enumerated rather than of what a transcript talked the model into. Any provenance field present in the model's own output is discarded, not merged. A fixture emits forged `source` and `project` from L1 and asserts they cannot affect pin eligibility.

   Raw `cwd` and canonical `project` are both retained: with only the canonical value, `tests/replay.sh --artifacts` could assert nothing about the encoder except that it agrees with itself. Keeping the input alongside the output makes `encode(cwd) == project` a real assertion.
5. Shared collectors run once for the date: changelog window, operator notes, X bookmarks, skills inventory (the union across adapters), `run-stats.txt`.
6. L2 runs once, on the globally configured engine, with `--tools Glob Read`. Its prompt is `PROMPT.md` followed by each enabled adapter's `facts.md`.
7. L2 prints the report to stdout, terminated by `AUTODREAM_REPORT_END`, followed by a pin block. `run.sh` slices from the last sentinel, validates, and writes `dreams/<date>.md` through a temp file and rename.
8. Pins dispatch to adapters, sequentially.
9. Consume gates run: vault note archive, bookmark mark-read, project memory GC. The first two are unchanged. GC is not; see below.

Steps 7 and 8 are ordered deliberately. The report reaches disk before any pin is applied, so a pin failure cannot cost a report.

### Report delivery

L2 has no `Write` tool, so it cannot write the report itself. It prints, and `run.sh` captures.

The parser contract, stated exactly, because an earlier draft said "slices from the last sentinel" and that reads as though the report were the text *after* it:

- **A sentinel is an exact standalone line, never a substring.** A line matches only if, after stripping a trailing `\r`, it equals the sentinel with no leading or trailing whitespace and nothing else on the line. Substring matching would let the pin fixture below — a JSON value containing the literal string `AUTODREAM_REPORT_END` — be selected as the delimiter and truncate the report at that point. Input is normalized to LF before scanning so a CRLF capture behaves identically.
- The report is everything **before** the selected `AUTODREAM_REPORT_END` line. Pins are the lines **between** an `AUTODREAM_PINS` line and an `AUTODREAM_PINS_END` line, both of which follow it.
- When more than one line matches `AUTODREAM_REPORT_END`, the **last** matching line is selected and the report is the text preceding it. This is what protects against a model that narrates a draft, corrects itself, and emits the real report second.
- A capture is a validated delivery when **at least one** matching line exists, the text preceding the **last** one is non-empty, and that text carries the `autodream:open-questions=` marker. Anything else is a truncated capture and goes to the retry loop. An earlier draft said "exactly one was selected", which contradicts last-wins: every two-sentinel capture would have retried, defeating the draft-then-corrected case the rule exists to rescue. The two-sentinel fixture asserts the second report is accepted, not that the capture is rejected.
- The pin block is optional. Its absence is a report with no proposed pins, not a failure.

A fixture covers each branch: no sentinel, two sentinels, sentinel with no marker, sentinel with no pin block, and a pin block containing the literal sentinel string inside a JSON value.

**`PROMPT.md` is rewritten, not reused.** Today's prompt instructs the model to write the report to a path (`prompts/PROMPT.md:183`), to edit `MEMORY.md` (`prompts/PROMPT.md:152`), to append to `touched-projects.txt` (`prompts/PROMPT.md:168`), and states it holds `Glob Read Write Edit` (`prompts/PROMPT.md:73`). Invoked with `Glob Read`, that prompt makes the model attempt impossible writes or omit required output. Migration step 4 produces a pure stdout prompt with every write instruction removed, and a test asserts the prompt text contains no write directive.

This is the same defect `autodream-merge` ships: it reuses cc-autodream's `PROMPT.md` verbatim under `--tools Glob Read`, with a header telling the model to print instead. None of that prompt's write instructions are satisfiable under its own invocation.

### Pin protocol

After the report sentinel, L2 emits one JSON object per line so nothing requires a multi-line parse:

```
AUTODREAM_REPORT_END
AUTODREAM_PINS
{"sources":["claude","omp"],"project":"-Users-x-sites","index_line":"...","body":"...","type":"feedback"}
AUTODREAM_PINS_END
```

**`sources` is model-controlled input and is validated as such.** It must be an array with at least one entry: `{"sources":[]}` would otherwise satisfy pair validation vacuously — every member of an empty set is valid — and apply nowhere, so a pin that reads as accepted silently does nothing. An empty or absent `sources` is rejected with `pins_invalid`. Each entry must match an enabled adapter name exactly, from the set the runner already resolved. Anything else is rejected and counted: a value such as `../../tmp` would otherwise resolve a command path outside `adapters/`. Path separators, `.`, and empty strings are rejected before any command path is constructed.

**Validation is on the observed `(source, memory_root, project)` triple, not on each field independently.** Checking that the source is enabled and that the project appears somewhere in the run is too weak: L2 could name a project that only OMP sessions touched, pair it with `claude`, and have the claude adapter write memory for a project Claude never worked in.

The runner already holds the exact set of observed triples. Each findings record carries the runner-stamped `source`, `memory_root` and canonical `project`, so the allowed set is a projection of the records this run actually wrote. A pin names a `(source, project)` pair; the runner **expands** it to every distinct observed triple matching that pair.

**One pair can legitimately map to several roots, and expanding rather than choosing is the point.** The same canonical project is one real directory, and a host running several config dirs works that directory from more than one of them — this host does exactly that. `-Users-x-repo` therefore has sessions under both `~/.claude` and `~/.claude-ds4`, one `source`, one `project`, two memory roots. Picking one root implicitly would drop the pin from the other, which is the multi-root loss this design set out to fix, reintroduced one layer down and harder to see. So the pin is applied once per matching triple, and GC runs once per triple that returned `0`.

A pair with no matching triple is rejected with `pins_rejected_pair`, a distinct counter from `pins_rejected_source`, because a well-formed source with an unobserved project is a different mistake from a fabricated adapter name. A fixture covers one `(source, project)` observed under two memory roots and asserts the pin lands in both and both are GC'd.

Validated pins route to `adapters/<source>/adapter.sh apply-pin` **once per distinct expanded `(source, memory_root, project)` triple**, not once per adapter. The `sources` array is deduplicated *before* expansion, so a pin naming `["claude","claude"]` expands the same set once rather than twice; but one `claude` entry that expands to two memory roots dispatches twice, which is the whole point of the expansion. Reading this as one dispatch per adapter would silently drop the pin from every root after the first.

**The adapter is handed an envelope, not the model's line.** For each expanded triple, `run.sh` constructs the `apply-pin` payload from the validated pin body plus that triple's `memory_root`. The model's line never reaches the adapter unmodified, and the adapter is never asked to work out which root it should write to — it is told.

**`apply-pin` signals its outcome by exit code**, because the orchestrator has to distinguish "wrote" from "declined" to know which triples deserve GC, and a prose reason on stdout is not something `run.sh` should be parsing. `0` means a pin was written, and only a `0` schedules `(adapter, memory-root, project)` for GC. `10` means a deliberate per-pin decline by an adapter that *does* have a store — the pin duplicates a pinned entry it must not rewrite, or the project's file is at its size cap — and the reason is printed for the log and counted, not treated as an error. "No store" is never an exit `10`, because such an adapter is short-circuited at the manifest and `apply-pin` is not spawned. Any other nonzero code is a failure, counted separately, and never schedules GC. A pattern with evidence in both harnesses therefore reaches both adapters. The claude adapter writes `MEMORY.md` and appends to `touched-projects.txt`; the lesson is never silently dropped, and never written where the originating harness cannot read it.

**An adapter declaring `writes_memory: false` is not invoked at all.** Its triples are observed, so a pin naming it passes pair validation; the orchestrator then short-circuits on the triple's non-writable state, counts `pins_declined_no_store`, and records the reason. That is a routing decision made from the manifest, and it is distinct from both an exit `10` and a `pins_rejected_pair`: a declaration means the process is never spawned, a `10` means an adapter that does have a store chose not to write this particular pin, and a rejected pair means the model named a combination this run never saw. A declarative manifest exists so the orchestrator can route without spawning a subprocess; invoking the adapter anyway would make the declaration dead weight.

**Pins apply sequentially.** Two pins for one project are read-modify-write against the same `MEMORY.md`, and `touched-projects.txt` is an append target shared across every pin in the run. Parallel dispatch loses updates. Sequential application costs nothing at this volume.

Lines that fail `jq` validation are counted and logged, never guessed at.

The existing memory rules survive intact inside the claude adapter: always pin with the marker, never rewrite an existing pinned entry, hold each index line under about 150 characters, keep the file within 200 lines and 25,000 bytes, and put longer bodies in a topic file with frontmatter.

### Memory GC

GC becomes an adapter operation. `run.sh` calls `adapter gc <memory-root> <project>` once per distinct `(adapter, memory-root, project)` triple whose `apply-pin` returned `0`, after every pin in the run has been applied. These are the same triples the pin expansion produced, deduplicated. Today's implementation is hard-coded to Claude storage — `proj="$PROJECTS_DIR/$encoded"` (`bin/run.sh:1296`) and `( cd "$cwd" && claude-memory gc )` (`bin/run.sh:1306`) — which cannot be correct for an adapter with a different store.

**The memory root is runner-stamped provenance, not a reconstruction and not a model-supplied field.** `adapter memory-root <session>` is called during enumeration, and its answer is stamped into the findings record alongside `source`, `cwd` and `project`, under the same rule: a value present in the model's own output is discarded. GC then uses the stamped root rather than rebuilding a path from `$PROJECTS_DIR`.

**For an adapter with `writes_memory: true`, the root is validated before the record is written.** It must be non-empty, absolute, and `realpath`-canonical, and it must exist as a directory. Anything else skips the session with `memory_root_invalid` and writes **no findings record at all** — not a record carrying an empty root. The distinction matters because the observed-triple set is a projection of the records: a record with `memory_root=""` would enter that set, authorize an `apply-pin`, and hand an adapter an empty root to write against, where a fallback or default-root write is exactly the silent misplacement this provenance chain exists to prevent, and GC would then run against the same empty target.

**A `writes_memory: false` adapter still contributes a triple**, with `memory_root` explicitly `null` and the triple marked non-writable. It is tempting to say such adapters simply never enter the set, but that makes the no-store short-circuit unreachable: with no observed triple, pair validation would reject an OMP-sourced pin as `pins_rejected_pair` before anything could decline it, and the report would call a legitimate cross-harness pin invalid instead of saying the harness has nowhere to put it. That distinction is the whole reason `source` is tracked — the remedy differs per harness, and "OMP has no memory store, so this is a rule or a hook" is a real answer while "unobserved pair" is a bug report about nothing.

So the order is: validate the pair against observed triples (an OMP triple is present, so it passes), then short-circuit on the triple's non-writable state, counting `pins_declined_no_store` and recording the reason. `apply-pin` is never spawned and GC is never scheduled for that triple.

Two fixtures pin this. A session whose `memory-root` returns empty under a *memory-writing* adapter produces no findings record, no pin dispatch, and no GC call. A cross-harness pin naming both `claude` and `omp` is written to the Claude root and reported as declined-no-store for OMP, counted under `pins_declined_no_store` and never under `pins_rejected_pair`.

That is what fixes the defect live in `main` today, which this change does not cause but must not inherit. The runner scans every configured Claude root since multi-root scanning landed (`bin/run.sh:294`), while GC resolves projects only under `$PROJECTS_DIR`, the primary root — so a pin written for a session in a secondary Claude profile is recorded and then skipped with "no project dir". Reconstruction is the bug; carrying the value the runner already knew is the fix. Tracked as `STRML/cc-autodream#52`.

A fixture asserts that a pin for a session enumerated from a secondary root is GC'd against that root, which is the case the current code silently skips.

## Failure handling

| Failure | Behavior |
| --- | --- |
| a shared dependency is missing (`jq`, `shasum`, `python3`) | hard failure at preflight with a named key; never a degraded run |
| the configured L2 engine binary is absent | hard failure at preflight, before L1 runs |
| adapter manifest missing or unparseable JSON | skip that adapter, log, continue |
| adapter `engine_bin` absent | disable that adapter, count, report; not fatal |
| every adapter disabled | hard failure; there is nothing to triage |
| `normalize`, `project`, `stats`, or `slim` exits nonzero | skip the session with that subcommand's own counter; partial output removed |
| `memory-root` returns empty, relative, non-canonical or absent for a `writes_memory: true` adapter | skip the session, count `memory_root_invalid`, write no findings record |
| a session path contains a newline | rejected at enumeration with `sessions_rejected_path`, logged with control characters escaped; a line-based `sessions.txt` cannot represent it |
| one path enumerated by two adapters | keep the first, log both, count `sessions_duplicate_path` |
| two distinct paths truncate to one hash | skip both, log both, count `sessions_hash_collision` |
| adapter directory basename is unsafe, disagrees with manifest `name`, or resolves outside the adapters root | refuse to load that adapter, count `adapters_rejected_identity` |
| L2 capture missing sentinel or marker | treated as truncated, retried per `AUTODREAM_L2_ATTEMPTS`, same as today |
| a pin line fails validation, or names an unknown source, or an unobserved `(source, project)` pair | counted and logged; the report is already on disk |
| `apply-pin` exits `10` | a deliberate decline; reason logged, `pins_declined_by_adapter` counted, no GC scheduled |
| `apply-pin` exits nonzero and not `10` | a failure; `pins_failed` counted and logged, no GC scheduled; never blocks anything downstream |

Unchanged from today: SIGPIPE hardening on the log path, the L1 retry rounds with a network wait between them, the L2 retry loop, the idempotency guard, the stale-report move-aside that disarms consuming on failure, the trailing-week `unassembled_dates` sweep, and the vault-note and bookmark consume gates.

## Telemetry

New keys in `run-stats.txt`, following the existing rule that a degraded measurement must say so rather than read as zero:

- `adapters_enabled` — comma-separated list.
- `adapters_unavailable` — `<name>=<reason>` per adapter that could not run.
- `sessions_by_source` — `claude=21,omp=33`. A source that drops to zero on a day the user worked in it is the signal that ingest broke.
- `sessions_duplicate_path`, `sessions_rejected_path`, `sessions_hash_collision`.
- `adapters_rejected_identity`.
- `normalize_failed`, `project_failed`, `stats_failed`, `slim_failed`, `memory_root_invalid`.
- `pins_proposed`, `pins_applied`, `pins_declined_no_store`, `pins_declined_by_adapter`, `pins_failed`, `pins_invalid`, `pins_rejected_source`, `pins_rejected_pair`.
- `l2_input_bytes` — the total size of the findings the aggregator was handed.

`runner_commit` and `runner_dirty` stay, and matter more after the rename, since the live install still symlinks into the working tree.

### Signal dilution, measured before it is solved

The panel raised that a lopsided day — 200 Claude sessions to 3 OMP — lets the larger source bury the smaller in a single L2 pass, and that nothing bounds the union against the aggregator's context window. Both are real risks. Neither is a measured problem yet: the one observed dual-harness day was 21 to 33.

The response is the same shape as this repo's existing issue #12 gate, which blocks chunk-summarization pending evidence it is needed. `l2_input_bytes` and `sessions_by_source` are recorded from the first run, the prompt is told the per-source counts so it can say plainly when one source is thin, and a threshold on `l2_input_bytes` logs a warning rather than silently truncating. A per-harness pre-summarization phase is built when the telemetry shows it is needed, not before. Building it now would add a phase, a prompt, and a failure mode to serve a day that has not happened.

## Tests

**The existing 297 assertions do not all survive unchanged, and claiming they do would be false.** The stdout-only L2 and the removal of `Write`/`Edit` necessarily invalidate every fixture that asserts on a report-path instruction, on the L2 tool flags, or on a model-written report file — `tests/mock-claude.sh` writes the report today, and under the new protocol it must print it. The honest contract is: existing *behavioral* coverage stays green, and the fixtures encoding the old delivery mechanism are rewritten as part of migration step 4 rather than deleted. The suite's assertion count is expected to rise, not hold. Six additions beyond that rewrite:

1. **Fixture adapter.** `adapters/_fixture/` exercises the full contract with neither real harness installed, using a synthetic transcript format. This is what makes the claim "adding codex later is one directory" checkable rather than aspirational. It is excluded from the default adapter set.
2. **Encoding regression.** A project fixture whose path contains a dot, an underscore, and a symlinked prefix. The bug in `merge-reports.sh:162` becomes a permanent test rather than a fixed defect.
3. **Linearizer rejection fixtures.** Malformed JSON, a dangling `parentId`, and a `parentId` cycle, each asserting a nonzero exit with no output. A replay corpus cannot prove these paths, because it only contains whatever happened to occur.
4. **Pin validation fixtures.** A `sources` entry containing a path separator, an unknown adapter name, a well-formed source paired with a project that source never touched, and an unparseable line — each asserting rejection with the right counter and no command path constructed. The pair case matters most: it is the one that a naive per-field check passes.

5. **Enumeration rejection fixtures.** A path containing a newline, two adapters claiming one path, and two paths forced onto one truncated hash — each asserting the named counter and that no findings record was written for the rejected session. The forced-collision case is constructed by stubbing the hash function, since a natural 48-bit collision cannot be produced in a test.
6. **Replay harness.** `tests/replay.sh` has two modes, because an archived findings dir and a live session store answer different questions and an earlier draft did not say which one it used.

   - `tests/replay.sh --artifacts <archived-findings-dir>` needs no session files. It re-derives what the runner can recompute from artifacts alone — the artifact hash for each line of the archived `sessions.txt`, the canonical project key for each findings record, sidecar parseability — and asserts the new code reaches the same answers the archived run did. This is the mode that proves the hash contract and the project encoding did not move, and it is the one that runs in CI, because archived dirs are small and self-contained.
   - `tests/replay.sh --ingest <session-root> <date>` needs live session files and runs the real enumerate, normalize, stats and gate path with `--no-l2`, asserting on source tags and skip counters. This is the mode that exercises the adapters, and it runs locally against the host's own stores rather than in CI.

   Neither mode tests operational reality. The panel was right that a replay harness will not catch an environment-specific execution failure of the `tee` SIGPIPE kind, which is the residual risk the single-cutover decision accepts.

Mocks: `tests/mock-claude.sh` stays; `tests/mock-omp.sh` comes across from `omp-autodream`. The suite continues to pin `AUTODREAM_CONFIG` into its sandbox so a developer's live vault is never written to, and continues to force `AUTODREAM_NETCHECK=0` and `AUTODREAM_RETRY_WAIT=0`.

Per this repo's own review rule, `/code-review` is a first pass and not the gate. A change of this size to `run.sh`, the adapters, and the prompts also goes through `/debate:run tight`, so at least one seat does not share Claude's blind spots.

## Migration

One branch, one cutover.

1. Add `preflight.sh`, `lib-project.sh`, and `adapters.sh`; build the claude adapter so that behavior is byte-identical to today. Convert the session list to NUL transport and add the source sidecar.
2. Write the OMP linearizer from scratch, with its rejection fixtures. Build the omp adapter around it, bringing `skills-inventory` and the dual-schema stats parsing across from `omp-autodream`.
3. Unify the two `SESSION_TRIAGE.md` files, which are four lines apart.
4. Rewrite `PROMPT.md` as a pure stdout prompt with every write instruction removed, and split the harness-specific remedy text into per-adapter `facts.md`.
5. Add the pin protocol with source and project validation, sequential application, and adapter-owned GC.
6. Add the fixture adapter, the encoding regression, the pin validation fixtures, and the replay harness.
7. Run the replay harness against archived corpora from several real dates.
8. Rename the repo, update `install.sh` and the adapter install hooks, re-run it, verify the symlinks resolve.
9. Archive `omp-autodream` and `autodream-merge` with pointers.

`STRML/cc-autodream#49` and `STRML/omp-autodream#15` add `AUTODREAM_L1_ONLY=1` so that each install stops after L1 and a separate tool aggregates. Under this design that seam has no consumer, because one runner already covers both harnesses. Both should be closed with an explanation rather than merged. `STRML/cc-autodream#47` is already closed; its linearizer design and its dual-schema `session-stats.sh` are the direct source for the omp adapter and should be credited, though the linearizer itself must be rewritten here since it was never merged anywhere.

## Defects found during review, filed separately

Two problems surfaced that exist in shipped code and are not caused by this change:

1. **GC ignores secondary Claude roots.** `bin/run.sh:294` scans every configured root; `bin/run.sh:1296` resolves projects only under `$PROJECTS_DIR`. Pins for sessions in a secondary profile are recorded and skipped.
2. **`omp-autodream` reads OMP session trees raw.** `omp-autodream/bin/run.sh:623` sets `readpath="$session"` and no linearizer exists in that repo, so triage sees branches the user abandoned.

## Open questions carried forward

1. Does the `sessions-source.txt` sidecar want to be keyed by hash or by path? Hash keeps lines short and matches every other artifact, but makes the file unreadable by eye during debugging.
2. Should `adapters/_fixture/` ship in the released tree or be generated by the test harness? Shipping it makes the contract self-documenting and adds a directory a user may reasonably wonder about.
