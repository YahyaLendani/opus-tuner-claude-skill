# opus-tuner

[![test](https://github.com/YahyaLendani/opus-tuner/actions/workflows/test.yml/badge.svg)](https://github.com/YahyaLendani/opus-tuner/actions/workflows/test.yml)

**Cost control for long Claude Code sessions on Windows.**

Claude Code bills by *context size × number of turns*. This bundle keeps the
model and effort level you chose, but puts a ceiling on the two things that
quietly dominate the bill: a context that grows without limit, and turns that
re-read it for work that did not need it.

Six hooks, a handoff skill, four effort gears, and a measuring tool. No network
calls, no API keys, no dependencies.

> **Status:** 0.2.0. Windows PowerShell 5.1 is the supported runtime. Both suites
> also run under `pwsh` 7 in CI (non-blocking); macOS and Linux are untested —
> see [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Why this exists

In an audit of one heavy week of Opus sessions, cache reads were **98.7% of all
tokens** and **78% of the API-equivalent cost**. Output — the thing people
usually try to shorten — was 0.3% of tokens and 12% of cost. Two sessions
accounted for 69% of the spend, both by running at 300–450k context per request.

That shape says the levers are, in order:

1. **Cap the context.** Every request re-reads all of it. Halving it halves the
   dominant line item.
2. **Stop paying for turns that did not need to happen.** A gear change or a
   subagent costs one extra request; it has to buy back more than that.
3. **Make the expensive turn rare.** Spend `max` effort when a wrong answer
   costs a full turn, not by default.

The bundle does those three things and gives you the instrument to check whether
they worked. It does **not** downgrade your model, silently compact your session,
or clear it for you.

## What it does

| Mechanism | Behaviour |
|---|---|
| **Tiered ceilings** | 150k routine, 250k deep. Deep is for refactors, hard debugging, architecture. Escalate-only: a session never drops back mid-flight. |
| **Hard wrap** | At the ceiling the `Stop` hook returns `decision: "block"` **once**, with a reason that tells the model to write the handoff brief. The ceiling becomes a gate, not a suggestion. |
| **Grace band** | Between the routine ceiling and +25k the tier steps up to deep instead of interrupting a task that is nearly finished. |
| **Effort gears** | `low` / `medium` / `xhigh` / `max` as one-turn skills. Default is `high` and costs nothing. The router only asks for a gear when the extra request pays for itself. |
| **Handoff, not compaction** | `/wrap` writes a brief from transcript facts; `/clear` starts fresh at ~500 tokens. Cheaper than `/compact`, which pays a full context read to summarize. |
| **Compaction is watched** | Every compaction is logged, and the first manual `/compact` in a session is refused once with a pointer to `/wrap` + `/clear`. Auto-compaction is never blocked. |
| **Decision log** | One CSV row per decision (not per prompt), so “did the gears ever pay?” is answerable a week later. |
| **Measurement** | `audit.ps1` reports per-session cache read/write, output, peak context, and cost. `stats.ps1` reports what the tuner decided. |

### Hooks

| Event | Script | What it does |
|---|---|---|
| `UserPromptSubmit` | `route.ps1` | Classifies the prompt, escalates the tier, picks a gear. |
| `Stop` | `stop.ps1` | 70% warning, hard wrap at the ceiling, grace escalation. |
| `PostToolUse` / `PostToolUseFailure` | `post-tool.ps1` | Counts consecutive failures and edited files (async; writes only on change). |
| `SessionStart` | `session-start.ps1` | Resets the tier; re-seeds from the handoff brief; warns about a config typo and the cost of resuming a large session. |
| `PreCompact` | `pre-compact.ps1` | Logs every compaction; refuses the first manual `/compact` per session. Never blocks auto. |
| `PreToolUse` *(optional)* | `pre-tool.ps1` | In `enforce` mode, refuses unbounded `Read`s at the ceiling. |

Everything except the hard wrap and the first manual `/compact` is advisory.
Hooks fail open: an error exits 0 and Claude Code continues.

## Install

**Requirements:** Windows 10/11, Claude Code 2.1 or newer, Windows PowerShell 5.1
(built in). No admin rights, no modules.

```powershell
git clone https://github.com/YahyaLendani/opus-tuner.git
cd opus-tuner
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

The installer:

- copies the six skills into `~/.claude/skills/` (or `$env:CLAUDE_CONFIG_DIR`);
- merges six hook events into `~/.claude/settings.json`, **keeping your existing
  hooks** and backing the file up first;
- adds a status line, unless you already have one;
- appends a marked token-discipline block to `~/.claude/CLAUDE.md`.

It is idempotent: running it again does not duplicate entries. Use `-Force` to
replace existing skill folders and an existing status line (both are backed up).
`-DryRun` prints the merged settings without writing.

Then restart Claude Code — or **Developer: Reload Window** in VS Code, which
reads hook config at session start.

```powershell
# optional: also register the PreToolUse read guard
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Force -Enforce
```

## Verify

```powershell
# 56 assertions: routing, hard wrap, compaction, handoff round trip, audit, timing
# (55 if ~/.claude/settings.json does not exist yet — the matcher check is skipped)
powershell -NoProfile -File skills\opus-tuner\scripts\selftest.ps1

# 43 assertions: install/upgrade/uninstall against a sandbox config dir
powershell -NoProfile -File tests\install-test.ps1

# is the install healthy? hooks registered, scripts present, config valid
powershell -NoProfile -File skills\opus-tuner\scripts\doctor.ps1
```

In Claude Code, `/hooks` should list `UserPromptSubmit`, `PostToolUse`,
`PostToolUseFailure`, `Stop`, `SessionStart`, `PreCompact`; `/skills` should list
`opus-tuner`, `gear-low`, `gear-medium`, `gear-xhigh`, `gear-max`, `wrap`.

## Configure

Defaults live in the scripts and are overridden by
`~/.claude/tuner.config.json`. Start with the ceilings and the mode:

```json
{
  "mode": "advise",
  "routineTokens": 150000,
  "deepTokens": 250000,
  "hardWrap": true,
  "blockManualCompact": true
}
```

- `mode`: `advise` (default), `enforce` (adds the read guard), `off` (silent).
- `hardWrap`: `false` restores the banner-only behaviour.
- `blockManualCompact`: `false` logs `/compact` without ever refusing it.
- Ceilings: lower them if you routinely hit the weekly limit; raise the routine
  one if you spend most of a session below it.

Every knob is documented in [docs/configuration.md](docs/configuration.md).

## Measure

```powershell
# per-session tokens and API-equivalent cost, newest 20 sessions
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20

# compare against a CSV captured before tuning
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20 -Baseline baseline.csv

# what the router decided, last 7 days
powershell -NoProfile -File skills\opus-tuner\scripts\stats.ps1 -Days 7
```

Take a baseline **before** tuning (`audit.ps1 -Csv baseline.csv`), then pass it
back with `-Baseline` after a week: the report prints peak context, cache read and
cost per request as a before/after table. Peak context should fall first; cost per
request falls last, because cache write and output do not scale with context the
way cache read does. [docs/measuring.md](docs/measuring.md) explains the method
and the traps.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes its hooks, its status line, its `CLAUDE.md` block, and its skill folders.
Your own hooks and settings stay. `-KeepSkills` keeps the folders; `-Purge` also
deletes `tuner.config.json` and the session state.

## Design constraints

- **It never runs `/clear`.** Hooks cannot invoke slash commands, and clearing a
  session unattended would throw away work you may still be reading.
- **It never changes your model.** Model choice belongs at a session boundary,
  where it does not invalidate the prompt cache.
- **Escalate-only.** A tier never drops mid-session, so a resumed 300k session is
  not instantly told to wrap.
- **Fail open.** A broken hook must never strand a session.
- **No telemetry.** The only writes are local state, the handoff file, and the
  settings file during install.

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Hook lifecycle, state schema, concurrency, latency budget |
| [docs/configuration.md](docs/configuration.md) | Every knob, modes, enforce setup, tuning guidance |
| [docs/measuring.md](docs/measuring.md) | How `audit.ps1` counts, how to capture a baseline |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Hooks not firing, VS Code quirks, quota questions |
| [docs/decisions.md](docs/decisions.md) | Why the design is shaped this way |
| [skills/opus-tuner/README.md](skills/opus-tuner/README.md) | Technical reference for the installed skill |

## License

MIT. See [LICENSE](LICENSE).
