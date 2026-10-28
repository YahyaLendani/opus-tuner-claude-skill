# Architecture

opus-tuner is six hooks, a small state file, and a set of CLI scripts. There is
no daemon, no database, and no network access.

## Lifecycle

```
session start
    │  session-start.ps1   reset tier · re-seed brief · config and resume warnings
    ▼
user prompt
    │  route.ps1           classify → escalate tier → pick gear
    ▼
tool calls
    │  post-tool.ps1      count consecutive failures; record edited files (async)
    ▼
response ends
    │  stop.ps1           70% warning · hard wrap at ceiling · grace escalation
    ▼
   /wrap  →  brief written
   /clear →  next session starts from the brief

   /compact (any time) → pre-compact.ps1   log it · refuse the first manual one
```

The optional `PreToolUse` hook sits between the prompt and the tool call and can
deny an unbounded `Read` at the ceiling. It is off unless installed with
`-Enforce`.

## Hook contracts

Claude Code sends JSON on stdin and reads JSON on stdout. The fields this bundle
uses:

| Input field | Used by |
|---|---|
| `session_id` | every hook — keys the state file |
| `transcript_path` | `route`, `stop`, `pre-tool` — context measurement |
| `prompt`, `permission_mode` | `route` — classification |
| `stop_hook_active` | `stop` — loop protection |
| `tool_name`, `tool_input` | `post-tool`, `pre-tool` |
| `cwd`, `source` | `session-start` — where the brief lives |
| `trigger` | `pre-compact` — `manual` or `auto` |
| `seconds_since_last_response` | `session-start` — not used, but available on resume |

| Output shape | Event | Effect |
|---|---|---|
| `hookSpecificOutput.additionalContext` | UserPromptSubmit, SessionStart | text enters the model's context |
| `decision: "block"` + `reason` | Stop | refuses the stop; the reason is shown to the model |
| `decision: "block"` + `reason` | PreCompact | refuses the compaction |
| `systemMessage` | Stop, SessionStart | shown to the user, **not** the model |
| `hookSpecificOutput.permissionDecision` | PreToolUse | allow/deny a tool call |

Banners go through `systemMessage` on purpose: a warning that costs tokens on
every response defeats the point of the tool. `PreCompact` discards
`systemMessage` entirely, which is why compaction is reported through the decision
log instead.

## Context measurement

`Get-ContextInfo` finds the **last** assistant `usage` block in the transcript and
sums `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`. That
sum is what the next request re-reads, which is what the ceiling is about — not
`cache_read` alone.

Three details matter:

- **Only the tail is read.** Transcripts reach hundreds of MB. The reader opens
  the file, seeks to `length - window`, and decodes UTF-8. It tries 128 KB, then
  512 KB, then 4 MB, because bookkeeping lines at the end can push the last usage
  block out of a smaller window.
- **The text is scanned, not parsed.** One transcript line can be hundreds of KB;
  `ConvertFrom-Json` on it costs ~200 ms in Windows PowerShell. A depth-counting
  scan (string-aware, so braces inside message text cannot unbalance it) is an
  order of magnitude cheaper.
- **Only top-level members are summed.** A usage object nests `iterations`, which
  repeats the same counts, and `cache_creation`, which breaks down
  `cache_creation_input_tokens`. Summing every numeric match double-counts. The
  parser cuts the block at the first nested `{` and reads the top-level keys.

That last point was a real bug in the first version of `audit.ps1`: every figure
it reported was exactly 2× too high. It is the reason both the audit and the
context reader share the same rule, and why `selftest.ps1` has a regression
assertion for nested usage objects.

## State

One JSON file per session: `~/.claude/state/tuner/<session_id>.json`.

```json
{
  "tier": "routine",
  "gear": "high",
  "files": ["C:/repo/src/auth.ts"],
  "fails": 0,
  "maxUses": 0,
  "nudged": {
    "soft": false,
    "ceiling": false,
    "escalated": false,
    "hardWrap": false,
    "compact": false
  },
  "updated": "2026-10-28T10:35:26.3511815+01:00"
}
```

- `tier` is `routine` or `deep`. It only ever moves up.
- `files` is capped at 60 entries; it drives the breadth signal (6+ files → deep).
- `fails` counts consecutive tool failures, capped at 9.
- `maxUses` rations `gear-max` per session.
- `nudged` makes each banner fire once per crossing. `hardWrap` is the one-shot
  guard for the blocking Stop decision, `compact` the one-shot guard for the
  blocking PreCompact decision.
- `updated` is written on every state change, which makes it a cheap liveness
  signal when checking that hooks are actually running.

Missing keys are backfilled from `New-State` on read, so an old state file from a
previous version keeps working.

## Concurrency and failure

`PostToolUse` is registered `async: true`, so it can run while the session
continues. Several tool calls can finish at once, and `route`/`stop` can write the
same file. `Write-State` uses `File.WriteAllText` with three retries 20 ms apart;
the last writer wins. Losing one counter update is harmless; blocking a tool call
is not.

The decision log uses `File.AppendAllText`. Two simultaneous appends can lose a
row. That is acceptable for a diagnostic log and much cheaper than locking.

Every hook body is wrapped in `try { } catch { }` and ends with `exit 0`. A hook
that throws must never strand a session. The cost is that a bug can be silent,
which is why the self-test asserts outputs rather than exit codes alone.

## Why PowerShell

The target is Windows, where Windows PowerShell 5.1 is already installed. A hook
runs in a fresh process on every prompt and every tool call, so startup dominates:
5.1 starts faster than `pwsh` 7 on the development machine, and adding a runtime
dependency would make installation worse. See the latency section of
[the technical reference](../skills/opus-tuner/README.md#latency) for the
measurements.

The trade-off is that each hook pays ~150 ms of process startup. That is the
price of not requiring a long-lived process, which Claude Code does not offer for
hooks.

## Security surface

The scripts read the transcript tail, the config, and the state directory. They
write state, the decision log, the handoff brief, and — during install/uninstall —
`settings.json`. They make no network calls and hold no credentials. See
[SECURITY.md](../SECURITY.md).
