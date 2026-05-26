# Session Triage — Layer 1 (haiku)

You are processing ONE Claude Code session transcript and emitting structured findings as JSON. You will be called many times in parallel — be fast, structured, and deterministic.

## Inputs (first two lines of this prompt)

```
SESSION_PATH=/absolute/path/to/session.jsonl
OUTPUT_PATH=/absolute/path/where/to/write/findings.json
```

Read those two values. Then:

1. **Read the session file** at `SESSION_PATH` with the Read tool. It is JSONL — one JSON object per line. If the file is >10000 lines, sample: head 2000, middle 2000, tail 2000.
2. **Extract structured findings** per the schema below.
3. **Write the JSON** to `OUTPUT_PATH` with the Write tool — exactly one JSON object, no prose around it.
4. Print `done` and exit. No commentary.

## What to look for

Quote 1-3 sentences of evidence for every finding. Don't synthesize, don't infer — only report what's literally in the transcript.

| Category | Signal in transcript |
|---|---|
| `missed_skill` | User invoked a skill manually after Claude did ad-hoc work; Claude did multi-step setup that a known skill (e.g. python-env-management, commit-and-verify) would have automated; Claude said "let me check the help" for a tool that has a skill wrapper. |
| `wrong_skill` | Claude invoked a skill that didn't fit; user corrected ("no use X instead"). |
| `sandbox_friction` | `Operation not permitted`, `dangerouslyDisableSandbox: true` retries, `/tmp` writes failing, permission prompts denied. |
| `memory_miss` | User says "I told you", "we established", "remember", "the same as last time"; Claude re-discovers a workaround that was used in a previous session. |
| `tool_loop` | Same command retried ≥3 times with minor variants (>2 close-but-different curl/grep/find variants in <10 turns). |
| `permission_prompt` | Commands the user repeatedly allowed or repeatedly denied that should be in `.claude/settings.json` allowlist/denylist. |
| `fabricated_id` | Claude quoted a SHA, PR number, line number, function name, or version that wasn't from a just-run command. |
| `stop_projection` | "you must be tired", "let's pick this back up", "we should stop", any variant. |
| `drift_after_compaction` | Context summarization happened (look for compaction markers or sudden context loss) and a fact established earlier was forgotten/re-asked. |
| `assumption_unsurfaced` | Claude proceeded with non-trivial work without an ASSUMPTIONS block when global CLAUDE.md required it. |

If the session is trivial (<10 turns, no tool calls) or only contains user-side test pings, emit an empty findings array. Don't pad.

## Output schema

Write EXACTLY this shape to `OUTPUT_PATH`. JSON only, no markdown fence, no prose.

```json
{
  "session_path": "/absolute/path/to/session.jsonl",
  "project": "encoded-cwd-folder-name",
  "started_at": "ISO8601 from first message if present, else file mtime",
  "turn_count": 42,
  "tool_call_count": 87,
  "tools_used": ["Bash", "Read", "Write", "Edit"],
  "skills_invoked": ["schedule", "python-env-management"],
  "models_used": ["claude-opus-4-7"],
  "notable_initiatives": ["one-line summary of the main thing the user worked on"],
  "findings": [
    {
      "category": "missed_skill",
      "severity": "high|medium|low",
      "what": "1-sentence pattern",
      "evidence_excerpt": "verbatim ~200-char quote",
      "proposed_rule": "concrete fix: skill to invoke, allowlist to add, or memory entry to write"
    }
  ]
}
```

If you encounter an error (file unreadable, malformed JSONL), emit:
```json
{"session_path": "...", "error": "what went wrong", "findings": []}
```

Cap findings at 10 per session — pick the highest-severity ones.

## Important

- Do NOT use search-sessions, grep across other sessions, or read any file besides the one at SESSION_PATH (you have just this session's scope).
- Do NOT write anywhere except OUTPUT_PATH.
- Do NOT update MEMORY.md, CLAUDE.md, or skills — Layer 2 owns aggregation; you only emit signal.
- Be fast. Aim for <30s per session.
