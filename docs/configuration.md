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
  "deepPatterns": "refactor|architect|root cause|race condition|deadlock|migrat|redesign|flaky|intermittent|memory leak|concurren|thread-safe|vulnerab|rewrite|overhaul|regression",
  "weakDeepPatterns": "why does|why is|why did|investigate|prove|optimi[sz]|performance",
  "bigOutputTokens": 6000,
  "bigOutputWarnings": 3,
  "weeklyDigest": true,
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

## Profiles

| Key | Default | Effect |
|---|---|---|
| `profile` | `dev` | the active profile: `dev` or `creative` |
| `profiles` | — | per-profile overrides, e.g. `{ "creative": { "routineTokens": 180000 } }` |
| `downshift` | `true` | `false` stops the router from ever picking `gear-low` |

Switch with `/profile` in Claude Code (no argument swaps, `/profile creative` or
`/profile dev` sets one, `/profile show` prints the active one), or run
`scripts/profile.ps1` directly. The switch edits the `"profile"` key and leaves
the rest of the file as it was. It persists across sessions and takes effect on
the next hook run, so the very next prompt is routed under the new profile.

| | dev | creative |
|---|---|---|
| `gear-low` downshift | on | off: its "no plan, no preamble" is wrong for prose |
| `gear-max` turns | 2 | 0: extra thinking buys little for prose |
| Deep tier vocabulary | code (`refactor`, `root cause`, ...) | long-form (`outline`, `chapter`, `story arc`, ...) |
| Added to the context | nothing | one note, ~100 tokens, at session start |

The profile is applied **after** the top-level keys, so switching always changes
behaviour even if you also set, say, `maxTurnsPerSession` at the top level. To
change what a profile does, override it under `profiles`.

The creative note is the only standing instruction a profile adds. `/profile
show` prints it verbatim, so you can check it against your own system prompt.
It is added at `startup`, `clear` and `compact`, not on `resume` or `fork`,
which already carry it. A misspelt profile name falls back to `dev` and is
reported at session start and by `doctor.ps1`.

## Classification vocabulary

`deepPatterns`, `weakDeepPatterns`, `mechanicalPatterns` and `bulkPatterns` are
.NET regular expressions, matched case-insensitively against the prompt. An
empty string means "no words", not "match everything".

- `deepPatterns` escalates the tier and picks `gear-xhigh` (or `gear-max` after
  two consecutive failures).
- `weakDeepPatterns` are words that also turn up in ordinary questions ("why
  is", "performance"). They count as deep only alongside a second signal: a
  failure already in this session, 3+ files edited, plan mode, or a prompt of
  400+ characters. The deep tier never drops back, so an everyday question that
  escalates would carry the 250k ceiling for the rest of the session.
- `mechanicalPatterns` can downshift to `gear-low`, subject to the context rules
  above.
- `bulkPatterns` marks breadth ("all", "every", "codebase").

Add vocabulary for your own domain — "terraform", "schema migration", "flaky
e2e" — rather than editing the scripts. Keep the lists short: every alternative
is matched on every prompt, and a false positive costs a tier for the rest of the
session.

## Automatic savings

| Key | Default | Effect |
|---|---|---|
| `bigOutputTokens` | 6000 | a single tool result at least this large (estimated at 4 characters per token) gets a one-line note on how to bound the next one; `0` turns it off |
| `bigOutputWarnings` | 3 | most notes per session, so a session that needs big outputs is not nagged |
| `weeklyDigest` | `true` | once every 7 days, the first fresh session start shows one line: gear switches and their re-read cost, escalations, hard wraps, compactions |

The output note covers `Bash`, `PowerShell`, `Read`, `Grep`, `Glob`, `WebFetch`
and MCP tools. Edit results are skipped: they echo the original file, which the
model never sees. The hook runs async, so Claude Code passes the note to the
model on its next request; nothing waits for it.

The weekly line is a `systemMessage`: you see it, the model does not, so it
costs no tokens. It reads only the decision log. Gear-switch cost is the logged
context size times the Opus cache-read rate, because each switch re-reads the
context once; `weekly.ps1` has the full report.

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
parses, that `routineTokens < deepTokens < autoCompactWindow`, that the seven skills for its mode
skills are installed with matching `name:` frontmatter, that every script parses,
that the state directory is writable, and — on POSIX — that `pwsh` is on `PATH`.
Exit code 0 means healthy; `-Json` gives the same result as machine-readable
output, including `version`, `advisory` and `skipped`. `-Root <dir>` checks a
different config dir.

Add `-Replay` to execute each registered command exactly as written, in a
throwaway config dir: six events, exit 0, and empty-or-valid-JSON output. It adds
about 3 seconds and catches what registration alone cannot — a quoting error in
the command string, a shell that cannot start the interpreter, or a hook that
writes non-JSON to stdout.

In `-NoHooks` (advisory) mode there is no `settings.json` to inspect, so the six
wiring checks are reported as `skip` and the doctor exits 0: the skills, config
and scripts are still validated, and nothing is written to the state directory.
The same happens automatically whenever `settings.json` registers no opus-tuner
hooks, which is what a vendored skills-only copy looks like. A *partial* wiring
still fails — some events registered and others missing is a broken install, not
a deliberate one. `-SkillsOnly` forces the advisory view when hooks do exist but
you only want to check the skills. `-Json` reports `advisory` and `skipped`
alongside `ok` and `failed`.

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

`doctor.ps1` validates the `effortLevel` of every entry under `modelSettings`, not
just `claude-opus-5-5`, so a new model name cannot turn the check into a silent
no-op. When you switch models, retarget the key:

```json
"modelSettings": { "claude-opus-6": { "effortLevel": "high" } }
```

`low`, `medium`, `high` and `xhigh` are the persisted values. `max` is a one-turn
routing choice; written to `settings.json` it is reported as invalid.
