# Architecture

opus-tuner is a set of hooks, small per-session state files, and CLI scripts. There
is no daemon, no database, and no network access.

## Lifecycle

```
session start
    │  session-start.ps1   reset tier · load a claimed handoff · config and resume notes
    ▼
user prompt
    │  route.ps1           classify → escalate tier → pick gear
    ▼
tool calls
    │  post-tool.ps1      count consecutive failures; record edited files (async)
    ▼
response ends
    │  stop.ps1           70% note · ceiling banner or optional prompt · grace escalation
    ▼
   /wrap  →  handoff drafted, filled in, verified
   /clear →  session-end.ps1 claims it · the next session-start.ps1 loads it,
             unless another /clear in the project is pending; then it only lists it

   /compact (any time) → pre-compact.ps1   log it · optionally refuse the first manual one
```

The optional `PreToolUse` hook sits between the prompt and the tool call and can
deny an unbounded `Read` at the ceiling. It takes both guard mode and an install
with `-Enforce`.

In monitor mode `route`, `post-tool` and `session-end` exit at once, and `stop` and
`session-start` report to the user without adding anything to the model's context.

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
| `cwd`, `source` | `session-start` — which handoffs belong to this project |
| `reason` | `session-end` — a `clear` claims the session's verified handoff |
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

`Get-ContextInfo` finds the **last** main-thread assistant record in the transcript
that reports tokens, and sums `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens`. That sum is what the next request re-reads, which is
what the ceiling is about — not `cache_read` alone.

Three details matter:

- **Only the tail is read.** Transcripts reach hundreds of MB. The reader opens
  the file, seeks to `length - window`, and decodes UTF-8. It tries 128 KB, then
  512 KB, then 4 MB, because bookkeeping lines at the end can push the last usage
  block out of a smaller window.
- **Lines are parsed, newest first.** `Read-UsageRecord` accepts only an assistant
  record's own `message.usage`, so spacing, field order, nested `iterations` and
  `cache_creation`, a `toolUseResult.usage` and usage quoted in message text cannot
  change the answer. An earlier version scanned the raw text for this, and could
  report a subagent's usage as the session's context.
- **Parsing stays cheap.** One transcript line can be megabytes of tool output, and
  `ConvertFrom-Json` over that is slow in Windows PowerShell. Strings too long to
  matter, or holding an escape, are emptied first, and a text check skips lines
  that cannot qualify. The usual case parses one record.

`audit.ps1` reads every line with the same function, so the two cannot disagree
about what a usage record is. It adds what a whole-file view needs: repeated records
count once, and each request is priced by its own model. See
[measuring.md](measuring.md).

Prices are in `_pricing.ps1`, which only the audit and the benchmark report load.
No hook needs a dollar figure, and each script a hook loads adds to its parse time.

## State

Two JSON files per session, under `~/.claude/state/tuner/`. `<session_id>.json` holds
control state, which decides what a hook may do next:

```json
{
  "tier": "routine",
  "gear": "high",
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
- `maxUses` rations `gear-max` per session.
- `nudged` makes each banner fire once per crossing. `hardWrap` is the one-shot
  guard for the blocking Stop decision, `compact` the one-shot guard for the
  blocking PreCompact decision.
- `updated` is written on every state change, which makes it a cheap liveness
  signal when checking that hooks are actually running.

`<session_id>.diag.json` holds the optional counters the tool hooks collect:

- `files` is capped at 60 entries; it drives the breadth signal (6+ files → deep).
- `fails` counts consecutive tool failures, capped at 9.
- `bigWarned` and `lowFailed` back the oversized-output note and the low-gear
  switch-off.

Missing keys are backfilled on read, so a state file from a previous version keeps
working.

## Concurrency and failure

`PostToolUse` is registered `async: true`, so it can run while the session continues
and finish after a later hook. Hence the two files: a late tool hook can lose a
counter, but it never writes control state.

`Update-State` holds a per-session lock file for its whole read-modify-write, and
replaces the file through a temporary one. The merge on top is monotonic: a tier only
rises, a flag only sets, a limit only grows, whatever the writers' order. A hook acts
on a decision (a block, a note) only after the state recording it is safely on disk,
so an interruption that cannot be recorded does not fire.

A damaged state file is replaced with one that treats every one-time interruption
as already used: missing a prompt is better than repeating one. Temp
files older than a day and old lock and diagnostic files are pruned at startup.

A hook that cannot get the lock within two seconds gives up and fails open, without
acting on a decision it could not save.

The decision log uses `File.AppendAllText`. Two simultaneous appends can lose a
row. That is acceptable for a diagnostic log and much cheaper than locking.

Every hook body is wrapped in `try { } catch { }` and ends with `exit 0`. A hook
that throws must never strand a session. The cost is that a bug can be silent,
which is why the self-test asserts outputs rather than exit codes alone.

## Platform layer

Every script dot-sources `_common.ps1`, which resolves the three platform
differences once:

```powershell
$script:OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$script:HomeDir   = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { ... }
$script:TunerRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $script:HomeDir '.claude' }
```

No hook contains a backslash path literal. `Join-Path` is always nested —
`Join-Path (Join-Path $root 'state') 'tuner'` — because a single literal
`'state\tuner'` is one filename on POSIX, not two directories.

The installer is the only place that knows which interpreter runs a hook. On
Windows it writes `& "<path>"` with `"shell": "powershell"`; on POSIX it writes
`pwsh -NoProfile -File "<path>"` with `"shell": "bash"`. `-ExecutionPolicy` is
emitted only on Windows, because `pwsh` rejects it elsewhere. The installer also
normalises line endings: CRLF on Windows, LF on POSIX, for `CLAUDE.md` and the
hook JSON.

The self-test follows the same rule. It builds an `$ExePrefix` (`-NoProfile` plus
`-ExecutionPolicy Bypass` on Windows only) and uses
`[System.IO.Path]::GetTempPath()` rather than `$env:TEMP`, so the same assertions
run on all three platforms.

## Why PowerShell

The target is Windows, where Windows PowerShell 5.1 is already installed. A hook
runs in a fresh process on every prompt and every tool call, so startup dominates:
5.1 starts faster than `pwsh` 7 on the development machine, and adding a runtime
dependency would make installation worse. See the latency section of
[the technical reference](../skills/opus-tuner/README.md#latency) for the
measurements.

macOS and Linux require `pwsh` 7 instead, because there is no built-in PowerShell
there. That is a deliberate trade: one implementation with a runtime dependency
beats two implementations that drift. A bash rewrite was considered and rejected;
see [decisions.md](decisions.md#13-pwsh-7-on-macos-and-linux).

The trade-off is that each hook pays ~150 ms of process startup. That is the
price of not requiring a long-lived process, which Claude Code does not offer for
hooks.

## Security surface

The scripts read the transcript tail, the config, and the state directory. They
write state, the decision log, the handoff brief, and — during install/uninstall —
`settings.json`. They make no network calls and hold no credentials. See
[SECURITY.md](../SECURITY.md).
