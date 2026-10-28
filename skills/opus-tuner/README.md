# opus-tuner — technical reference

Token-budget control for long Claude Code sessions on a fixed model (Opus, high).

Nothing here calls a third-party endpoint, needs an API key, or runs `/clear` for
you. The repo-level [README](../../README.md) covers installation; this file is the
reference for what is wired where and why. The scripts run on Windows PowerShell
5.1 and on `pwsh` 7 (macOS, Linux, and Windows); see
[docs/platforms.md](../../docs/platforms.md) for the platform layer.

## What is wired where

| Piece | Location | Cost |
|---|---|---|
| Rules the model always sees | `~/.claude/CLAUDE.md` (token discipline block) | ~130 tok/turn (block is 473 chars) |
| Decision playbook | `skills/opus-tuner/SKILL.md` | 0 until invoked |
| Deep tactics | `skills/opus-tuner/references/playbook.md` | 0 until read |
| Effort gears | `skills/gear-{low,medium,xhigh,max}` | ~100 tok/turn total (descriptions stay visible so a gear can be picked when the router is silent) |
| Handoff writer | `skills/wrap` + `scripts/brief.ps1` | 0 until invoked |
| Portable rules | `skills/claude-skill` | 0 until invoked; for clients without hooks |
| Hooks | `~/.claude/settings.json` | 0 tokens |
| Status line | `settings.json` → `statusline.ps1` | 0 tokens |

## The knobs

`~/.claude/tuner.config.json`. Every key is optional; missing keys fall back to
the defaults below.

| Key | Default | Meaning |
|---|---|---|
| `mode` | `advise` | `off` silences everything, including the brief re-seed; `advise` banners only; `enforce` also refuses bulk reads at the ceiling |
| `routineTokens` | 150000 | routine ceiling |
| `deepTokens` | 250000 | deep ceiling; `autoCompactWindow` sits above it at 300000 |
| `graceTokens` | 25000 | band above the routine ceiling where the tier steps up instead of wrapping |
| `nudgeAt` | 0.7 | fraction of the ceiling for the first warning |
| `maxTurnsPerSession` | 2 | hard cap on `gear-max` turns |
| `minCtxForDownshift` | 100000 | below this a gear-down never pays for its extra request |
| `downshiftRequiresBulk` | true | below 200k, bulk wording must justify the extra request |
| `hardWrap` | true | Stop hook refuses the stop once at the ceiling, forcing the brief |
| `blockManualCompact` | true | PreCompact refuses the first manual `/compact` per session; auto is never blocked |
| `logDecisions` | true | one row per decision in `state/tuner/decisions.csv` |
| `deepPatterns` / `mechanicalPatterns` / `bulkPatterns` | regex | editable classification vocabulary |

Two environment variables exist for tests and experiments:
`OPUS_TUNER_CONFIG` and `OPUS_TUNER_STATE` override the config file and state
directory. `CLAUDE_CONFIG_DIR` relocates the whole `~/.claude` tree, which is how
the test suites stay away from a live install.

## Scripts

| Script | Runs on | Notes |
|---|---|---|
| `route.ps1` | UserPromptSubmit | classify, escalate tier, pick gear. Escalate-only. |
| `post-tool.ps1` | PostToolUse / PostToolUseFailure | counts failures, tracks edited files, writes state only when a signal changed (it runs on every tool call). Matcher covers `Bash` **and** `PowerShell` — on Windows the shell tool is `PowerShell`, and missing it latches the repair-loop signal. |
| `pre-tool.ps1` | PreToolUse (Read) | enforce mode only; refuses unbounded reads at the ceiling |
| `stop.ps1` | Stop | two-stage banner; blocks the stop once at the ceiling to force the brief |
| `session-start.ps1` | SessionStart | resets tier; re-seeds from `.claude/handoff.md` on `clear`, or on `startup` when the brief is under 24 h old; warns (via `systemMessage`, 0 model tokens) about a malformed config and the cost of resuming a large session |
| `pre-compact.ps1` | PreCompact | logs every compaction; blocks the first manual `/compact` per session. Auto is never blocked |
| `brief.ps1` | manual (`/wrap`) | writes `.claude/handoff.md` from transcript facts |
| `ctx.ps1` | manual | current context vs ceiling |
| `audit.ps1` | manual | per-session cache read/write, output, peak context, cost; `-Baseline x.csv` prints deltas |
| `stats.ps1` | manual | what the tuner decided: actions, context at each, per day |
| `weekly.ps1` | manual | audit + stats against the newest baseline, written to `state/tuner/weekly-<date>.txt` |
| `doctor.ps1` | manual | install health check: hook wiring, config validity, skills, script parse, state writable. `-Replay` executes the registered commands too |
| `statusline.ps1` | status line | live `ctx/ceiling`, tier, effort, 5h and 7d windows |
| `selftest.ps1` | manual / CI | 57 assertions against a synthetic transcript |

## Hard wrap

At the ceiling, `stop.ps1` returns `decision: "block"` with a reason that tells
the model to run `/wrap` and hand back to you. This is the only part of the
bundle that cannot be ignored, and it is what makes the ceiling a gate instead of
a suggestion.

Three limits keep it from becoming a trap:

- it fires **once per crossing** (`nudged.hardWrap`), and never when
  `stop_hook_active` is set, so a model that ignores the reason can still finish
  the turn;
- Claude Code caps consecutive continuations at 8 independently of this hook;
- `"hardWrap": false` restores banner-only behaviour.

The block never runs `/clear` for you. It cannot — hooks cannot invoke slash
commands — and clearing a session unattended would throw away work you may still
be reading.

## Compaction

Compaction is the failure mode this bundle exists to replace, so it is watched
rather than ignored. `pre-compact.ps1` receives `trigger: manual|auto` and does
two things:

- logs the event (`compact-manual`, `compact-auto`, or `compact-blocked`) with the
  context size, so `stats.ps1` can count how often it happens;
- refuses the **first** manual `/compact` per session (`nudged.compact`), with a
  reason that points at `/wrap` then `/clear`. A second `/compact` proceeds.

Automatic compaction is never blocked. If it fires to recover from a
context-limit error the API already returned, blocking it surfaces that error and
fails the request — worse than the compaction. `PreCompact` also discards
`systemMessage`, which is why the log is the only reporting channel.

## Decision log

`route.ps1` and `stop.ps1` append one row per *decision* — not per prompt — to
`state/tuner/decisions.csv`: time, session, context, tier, gear, action. Rotates
at 1 MB, keeps one previous file. `stats.ps1` answers "what did it actually do":

```powershell
# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\stats.ps1" -Days 7
```

```sh
# macOS / Linux
pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/stats.ps1" -Days 7
```

Rows at small context mean a threshold is too low; several `hard-wrap` rows in a
day mean the ceiling is being treated as a suggestion.

## Model and effort (verified against the 2.1.312 settings schema)

The session model is `"model": "opus"`, which resolves to **Opus 5.5** on the
Anthropic API. Its effort level is set per model, because that is the only form
Opus 5.5 reads:

```json
"modelSettings": { "claude-opus-5-5": { "effortLevel": "high" } }
```

The top-level `"effortLevel"` is deliberately *not* the mechanism for Opus 5.5:
the docs state that a top-level `effortLevel` "doesn't count for Opus 5.5", which
starts at `medium` unless a per-model level is saved. Within one settings file the
per-model level wins, so Opus runs at `high` and the top-level value only applies
to older models and to subagent models that have no saved level of their own.
`claude-opus-5-5` is the canonical name Claude Code sends, confirmed from
transcripts.

A gear's `effort:` frontmatter applies to **that turn only**; later turns fall
back to the resolved session level. `gear-max` uses `effort: max`, which Opus 5.5
supports even though `max` is not a valid *persisted* `effortLevel` value.

## In VS Code, the terminal, and Desktop

All three run the same Claude Code binary and read the same
`~/.claude/settings.json`, so the hook set is identical. The VS Code extension
ships its own CLI binary (`resources/native-binary/claude.exe` in
`%USERPROFILE%\.vscode\extensions\anthropic.claude-code-*`), so the panel does
**not** use whatever `claude` is on PATH — the two can be different versions.
`~/.claude/settings.json` is shared by both, so hooks, `skillOverrides` and
`autoCompactWindow` apply either way.

Two differences that matter:

- **Reload after editing hooks.** Each client reads settings at session start. The
  terminal needs a restart, the panel needs *Developer: Reload Window* (or a
  restart of the extension host), and the Desktop app needs a restart. Then check
  `/hooks` shows `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Stop`,
  `SessionStart`, `PreCompact` and `/skills` lists the seven skills.
- **New conversations usually start as `startup`, not `clear`.** The panel's
  new-chat button does not always emit the `/clear` source, so
  `session-start.ps1` also re-seeds from `.claude/handoff.md` on `startup` when
  the brief is under 24 hours old. A stale brief is ignored rather than
  resurrecting finished work.

A fresh conversation with no brief is the safest moment to change model or
effort; that is what `SessionStart` does, and it is why nothing in this bundle
switches mid-session.

In the panel, `/clear` is also available as `/reset` and `/new`. The custom
`statusLine` is a terminal-UI feature and is not drawn by the graphical panel or
the Desktop app, which have their own built-in context indicator; enable
`claudeCode.useTerminal` if you want the custom bar.

## Latency

Measured on one Windows 11 machine (Windows PowerShell 5.1, no `pwsh`). A blocking
hook is **~440–490 ms** end to end. Almost none of that is the tuner's own work:

| Cost | Time |
|---|---|
| `powershell.exe -NoProfile` start (measured with a no-op script) | ~150 ms |
| parse `_common.ps1` + the hook | ~50 ms |
| first `ConvertFrom-Json` in the process (the config read) | ~90 ms |
| first file read and regex use (the transcript tail) | ~100 ms |
| state read/write, classification, decision append | ~30 ms |

Once those engines are warm, the tuner's own work is ~20 ms: the same 512 KB tail
read costs 9 ms on the second call inside one process, and `Find-LastUsage` 1 ms.
The rest is one-time warm-up that every PowerShell hook pays, and it cannot be
avoided without a long-lived hook process, which Claude Code does not offer. This
is also why the two JSON parses are not worth merging: parsing the config first
moves the ~90 ms assembly load onto the hook input, not away from it.

Where it lands:

| Hook | Blocking? | Measured | Frequency |
|---|---|---|---|
| `route.ps1` | yes | ~450–490 ms | once per prompt |
| `stop.ps1` | yes | ~440–460 ms | once per response |
| `statusline.ps1` | UI only | ~330–360 ms | per message |
| `post-tool.ps1` | **no** (`async: true`) | ~310–360 ms | per tool call |

Three optimisations were measured and rejected because they did not move the
number: a hand-rolled flat-JSON config reader (the assembly load just moves to the
input parser), a 512 KB → 128 KB first read window (the tail decode is not the
bottleneck; the first read costs 45 ms at 128 KB and 9 ms at 512 KB once warm),
and a backwards `LastIndexOf` scan instead of collecting every `"usage"` match
(2.1 ms vs 6.5 ms on a 137 MB transcript, ~1% of hook time).

### Why not PowerShell 7 on Windows

PowerShell 7 was installed, measured, and removed on the development machine. It
was **slower** there, and leaving it installed is actively harmful because Claude
Code auto-detects `pwsh.exe` on PATH for every `shell: "powershell"` hook:

| | Windows PowerShell 5.1 | PowerShell 7.6.9 (MSI) | PowerShell 7.6.9 (MSIX) |
|---|---|---|---|
| bare start | **132 ms** | 235 ms | 271 ms |
| `route.ps1` | **~450 ms** | 550–620 ms | ~590 ms |
| `post-tool.ps1` | **~310 ms** | ~470 ms | — |

Process creation is already slow on that box (5.1 at 132 ms against a typical 80),
so pwsh's larger .NET runtime costs ~100 ms that its faster JSON parsing never
wins back. The MSIX/Store build is slower still. Re-measure before reinstalling
on different hardware; do not assume the usual "pwsh is faster" advice applies.

This is a Windows measurement and says nothing about macOS or Linux, where `pwsh`
is the only option and the same ~150 ms startup floor applies. See
[docs/platforms.md](../../docs/platforms.md).

## Enforce mode

`mode: "enforce"` only takes effect once the `PreToolUse` hook is registered,
which is disabled by default because it costs another blocking invocation on
every `Read`. Register it with:

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Force -Enforce
```

```sh
# macOS / Linux
./install.sh -Force -Enforce
```

Then set `"mode": "enforce"` in `tuner.config.json`.

## Removing it

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

```sh
# macOS / Linux
pwsh -NoProfile -File uninstall.ps1
```

That removes only this bundle's hooks, status line, `CLAUDE.md` block, and skill
folders. `-KeepSkills` keeps the folders; `-Purge` also removes
`tuner.config.json` and `state/tuner`.
