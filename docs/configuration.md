# Configuration

All settings are optional. The defaults live in
`skills/opus-tuner/scripts/_common.ps1`; a JSON file overrides them key by key.

```
~/.claude/tuner.config.json
```

If `CLAUDE_CONFIG_DIR` is set, the file is read from `$CLAUDE_CONFIG_DIR` instead.

## Full example

```json
{
  "mode": "advise",
  "routineTokens": 150000,
  "deepTokens": 250000,
  "graceTokens": 25000,
  "nudgeAt": 0.7,
  "maxTurnsPerSession": 2,
  "minCtxForDownshift": 100000,
  "downshiftRequiresBulk": true,
  "hardWrap": true,
  "blockManualCompact": true,
  "logDecisions": true,
  "deepPatterns": "refactor|architect|root cause|race condition|deadlock|migrat|redesign|why does|why is|why did|flaky|intermittent|investigate|prove|optimi[sz]|memory leak|performance|concurren|thread-safe|vulnerab|rewrite|overhaul|regression",
  "mechanicalPatterns": "rename|format|lint|prettier|eslint|typo|bump|commit|git status|run tests|run the tests|npm test|chmod|move file|copy file|list files|add header|add license",
  "bulkPatterns": "\\ball\\b|every|across|each file|multiple files|whole repo|whole project|codebase|batch|bulk|throughout"
}
```

A malformed file is ignored in favour of the defaults rather than breaking the
session.

## Mode

| Value | Behaviour |
|---|---|
| `advise` (default) | Banners and injected guidance only. Nothing is ever denied. |
| `enforce` | Adds the `PreToolUse` read guard **if it is registered**. |
| `off` | Every hook exits immediately, including the brief re-seed. |

`enforce` is two switches: the config value and the hook registration. Register
the hook once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Force -Enforce
```

The guard costs one extra blocking PowerShell invocation per `Read`, so it is off
by default even in `enforce` mode.

## Ceilings

| Key | Default | What it controls |
|---|---|---|
| `routineTokens` | 150000 | the ceiling for an ordinary session |
| `deepTokens` | 250000 | the ceiling after an escalation |
| `graceTokens` | 25000 | how far past routine a session may run before it is asked to wrap |

`deepTokens` must stay below Claude Code's `autoCompactWindow` (300000 in the
installed settings). Otherwise the auto-compactor fires before the handoff does,
which is the outcome this bundle exists to avoid.

**How to choose.** Look at `audit.ps1 -Recent 20` and find your median `PeakCtxK`.
If most sessions peak below 120k, the routine ceiling is not binding and you can
leave it. If sessions routinely run at 300k+, lower `routineTokens` first; it is
the one that fires most often. Raise `deepTokens` only if legitimate deep work is
being interrupted.

**The grace band is not a second ceiling.** Between `routineTokens` and
`routineTokens + graceTokens`, the tier steps up to deep instead of asking for a
wrap. That prevents cutting a nearly-finished task at the line. Beyond the band,
the ceiling wins and the hard wrap applies.

## Hard wrap

| Key | Default | Effect |
|---|---|---|
| `hardWrap` | `true` | the Stop hook returns `decision: "block"` once at the ceiling |

The block fires at most once per crossing and never when `stop_hook_active` is
set. Set it to `false` to keep the banner without ever refusing a stop.

The block does not clear your session. It asks the model to run `/wrap`; pressing
`/clear` remains your action.

## Compaction

| Key | Default | Effect |
|---|---|---|
| `blockManualCompact` | `true` | refuse the first manual `/compact` per session |

The bundle's argument is that a handoff plus `/clear` beats `/compact`: compaction
pays a full context read to write a summary, and that summary is then re-read on
every later request. So the first `/compact` in a session is refused once, with a
reason that points at `/wrap` and `/clear`. Running `/compact` again proceeds —
a nudge, not a wall.

Auto-compaction is **never** blocked. When it fires to recover from a
context-limit error the API already returned, blocking it surfaces that error and
fails the request. Every compaction, manual or auto, is still recorded in the
decision log (`compact-manual`, `compact-auto`, `compact-blocked`), so `stats.ps1`
can tell you how often the thing this bundle exists to avoid actually happens. A
refused `/compact` is logged as `compact-blocked` **instead of** `compact-manual`:
one row per event, so a refusal never inflates the count.

`"blockManualCompact": false` keeps the logging and drops the block.

## Gear routing

| Key | Default | Effect |
|---|---|---|
| `minCtxForDownshift` | 100000 | below this context, a gear-down never fires |
| `downshiftRequiresBulk` | true | below 200k, the prompt must also look bulk for a downshift |
| `maxTurnsPerSession` | 2 | how many turns may use `gear-max` |

A gear change costs one extra request that re-reads the whole context, so a
downshift only pays when the context is already large and the turn is genuinely
mechanical. Raising `minCtxForDownshift` makes the router quieter; lowering it
makes it spend more requests on cheap turns.

## Classification vocabulary

`deepPatterns`, `mechanicalPatterns` and `bulkPatterns` are .NET regular
expressions, matched case-insensitively against the prompt.

- `deepPatterns` escalates the tier and picks `gear-xhigh` (or `gear-max` after
  two consecutive failures).
- `mechanicalPatterns` can downshift to `gear-low`, subject to the context rules
  above.
- `bulkPatterns` marks breadth ("all", "every", "codebase").

Add vocabulary for your own domain — "terraform", "schema migration", "flaky
e2e" — rather than editing the scripts. Keep the lists short: every alternative
is matched on every prompt, and a false positive costs a tier for the rest of the
session.

## Decision log

| Key | Default | Effect |
|---|---|---|
| `logDecisions` | `true` | append one row per decision to `state/tuner/decisions.csv` |

The log rotates at 1 MB and keeps one previous file. `stats.ps1` summarises it.
Disable it if you do not want the file; nothing else reads it.

## Environment overrides

| Variable | Effect |
|---|---|
| `CLAUDE_CONFIG_DIR` | relocates the whole `~/.claude` tree, including config and state |
| `OPUS_TUNER_CONFIG` | points at a different config file |
| `OPUS_TUNER_STATE` | points at a different state directory |

The last two exist for the test suites and for experiments. They are not needed
in normal use.

## Diagnosing

```powershell
# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\doctor.ps1"
```

```sh
# macOS / Linux
pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/doctor.ps1"
```

Checks that the hooks are registered and their scripts exist, that the config
parses, that `routineTokens < deepTokens < autoCompactWindow`, that all seven
skills are installed with matching `name:` frontmatter, that every script parses,
that the state directory is writable, and — on POSIX — that `pwsh` is on `PATH`.
Exit code 0 means healthy; `-Json` gives the same result as machine-readable
output. `-Root <dir>` checks a different config dir.

Add `-Replay` to execute each registered command exactly as written, in a
throwaway config dir: six events, exit 0, and empty-or-valid-JSON output. It adds
about 3 seconds and catches what registration alone cannot — a quoting error in
the command string, a shell that cannot start the interpreter, or a hook that
writes non-JSON to stdout.

In `-NoHooks` (advisory) mode the hook checks report "no hooks registered" rather
than failing, because that is the intended state.

## Optional: trimming skill descriptions

Claude Code sends every installed skill's description to the model on every
turn. If you do not rely on auto-invoking a skill, you can reduce it to its name
in `~/.claude/settings.json`:

```json
"skillOverrides": {
  "some-skill": "name-only"
}
```

This saves roughly 20–100 tokens per turn per skill. Do **not** do this to skills
you expect the model to discover on its own — it removes the text that explains
when to use them. The gears and `/wrap` are safe candidates because the hook and
`CLAUDE.md` name them explicitly, but the bundle leaves the choice to you and
does not modify this key during install.

## Model and effort

Model choice is not a tuner setting; it belongs in `settings.json`:

```json
"model": "opus",
"modelSettings": { "claude-opus-5-5": { "effortLevel": "high" } }
```

The per-model form is the one Opus 5.5 reads. A top-level `effortLevel` applies to
older models and to subagents without a saved level. See
[the technical reference](../skills/opus-tuner/README.md#model-and-effort-verified-against-the-21312-settings-schema).
