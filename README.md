# opus-tuner/claude-skills

[![test](https://github.com/YahyaLendani/opus-tuner-claude-skill/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/YahyaLendani/opus-tuner-claude-skill/actions/workflows/test.yml?query=branch%3Amain)
[![version](https://img.shields.io/github/v/release/YahyaLendani/opus-tuner-claude-skill?label=version&style=flat)](https://github.com/YahyaLendani/opus-tuner-claude-skill/releases)
[![license](https://img.shields.io/github/license/YahyaLendani/opus-tuner-claude-skill)](LICENSE)
[![platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20macOS%20%7C%20Linux-blue)](docs/platforms.md)
[![code](https://img.shields.io/github/languages/top/YahyaLendani/opus-tuner-claude-skill)](https://github.com/YahyaLendani/opus-tuner-claude-skill/search?l=powershell)
[![dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](#design-constraints)

**Cost control for long Claude Code sessions on Windows, macOS and Linux.**

Claude Code bills by *context size × number of turns*. This bundle keeps the
model and effort level you chose, but puts a ceiling on the two things that
quietly dominate the bill: a context that grows without limit, and turns that
re-read it for work that did not need it.

Six hooks, seven skills per install, a handoff writer, four effort gears, two
profiles, and a measuring tool. No network calls, no API keys, no dependencies.

> **Status:** 0.6.1. Windows PowerShell 5.1 and `pwsh` 7 are both supported; CI
> runs the full suite on Windows, Ubuntu and macOS. Claude Code is the only
> requirement — the terminal, the VS Code panel and the Desktop app all load the
> same hooks. Plain claude.ai and Desktop (no hooks) use the portable
> [`claude-skill`](skills/claude-skill/SKILL.md) instead.

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

The status line is the whole state at a glance — context against the ceiling, the
tier, the effort level, and both rate-limit windows:

```text
Opus 5.5 | high | [#####.....] 78k/150k 52% | routine | 5h 34% | 7d 12%
```

At 70% it adds one line, and at the ceiling it adds the instruction that matters:

```text
Opus 5.5 | high | [########..] 132k/150k 88% | routine | 5h 61% | 7d 22%
-> finish this unit, then /wrap
```

That is the real output of `statusline.ps1` for a sample session, with the colour
codes stripped. The bar turns yellow at 70% and red at 90%.

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
| **Automatic savings** | Weak trigger words (`why is`, `performance`) only raise the ceiling alongside a second sign of hard work. One oversized tool result gets a single ~40-token note on how to bound the next one. The at-ceiling note is said once, not every prompt. Each install mode skips the skill it cannot use. A weekly one-line summary shows what the tuner did and what its gear switches cost, at zero tokens. If low-effort turns keep hitting failures, the low gear switches itself off for 14 days; nothing ever lowers a ceiling on its own. |
| **Profiles** | `/profile` swaps between **dev** (the default, adds nothing) and **creative** (no `gear-low` downshift, no `gear-max`, deep tier on long-form work, one ~100-token note). `/profile show` prints exactly what is in effect. Persists across sessions. |
| **Portable mode** | No hooks at all: `-NoHooks` installs the rules into `CLAUDE.md` only. The `claude-skill` skill carries the same discipline into Desktop and claude.ai, where hooks do not exist. |

### Hooks

| Event | Script | What it does |
|---|---|---|
| `UserPromptSubmit` | `route.ps1` | Classifies the prompt, escalates the tier, picks a gear. |
| `Stop` | `stop.ps1` | 70% warning, hard wrap at the ceiling, grace escalation. |
| `PostToolUse` / `PostToolUseFailure` | `post-tool.ps1` | Counts consecutive failures and edited files; flags one oversized tool result with a short note, at most three per session (async; writes only on change). |
| `SessionStart` | `session-start.ps1` | Resets the tier; re-seeds from the handoff brief; warns about a config typo and the cost of resuming a large session; once a week, shows a one-line summary of what the tuner did. |
| `PreCompact` | `pre-compact.ps1` | Logs every compaction; refuses the first manual `/compact` per session. Never blocks auto. |
| `PreToolUse` *(optional)* | `pre-tool.ps1` | In `enforce` mode, refuses unbounded `Read`s at the ceiling. |

Everything except the hard wrap and the first manual `/compact` is advisory.
Hooks fail open: an error exits 0 and Claude Code continues.

## Dev and creative profiles

The bundle's defaults are tuned for code: drop to a low-effort gear for
mechanical edits, spend extra thinking on race conditions, raise the ceiling for
refactors. Those rules misfire on writing. A "no plan, no preamble" gear is the
wrong instruction for a chapter, and "refactor" is not how anyone asks for a
rewrite of the opening scene. So there are two profiles, and one command swaps
them.

```text
/profile            swap dev <-> creative
/profile creative   switch to creative
/profile dev        switch back to dev
/profile show       print the active profile and the exact instruction it adds
```

| | **dev** (default) | **creative** |
|---|---|---|
| For | code, debugging, refactors | writing, editing, brainstorming, worldbuilding |
| Low-effort gear (`gear-low`) | used for bulk mechanical work at large context | never: its "act directly, no preamble" is wrong for prose |
| Max-effort gear (`gear-max`) | up to 2 turns per session, on a hard problem that has already failed twice | never: extra thinking buys little for prose quality |
| Deep tier (250k ceiling) triggered by | `refactor`, `root cause`, `race condition`, ... | `outline`, `chapter`, `story arc`, `rewrite`, `manuscript`, ... |
| Added to the model's context | nothing | one note, ~100 tokens, at session start |
| Ceilings, hard wrap, handoff, `/compact` guard | on | on, unchanged |

Switching prints the result, and the model reads it, so the change applies from
the next prompt of the current session as well as every later one. This is the
real output of the switch on a config that already set a 140k routine ceiling:

```text
Switched from dev to creative.

opus-tuner profile: creative
  gear-low downshift : off
  gear-max turns     : 0 per session
  ceilings           : 140k routine, 250k deep
  deep tier on       : rewrite|restructure|overhaul|outline|story arc|plot|worldbuild|chapter|manuscript|long-form|screenplay|style guide|series

Instruction in effect (also added at the start of every new session):
[tuner] profile=creative: this session is writing or ideation, not code. Drafts, options and full prose are the work: write at the length the piece needs, offer distinct alternatives when exploring, and keep the user's voice unless asked to change it. Tool rules (batch calls, grep before read) still apply when you use tools. Do not restate the brief or paste back unchanged text; quote only what changed.
```

That note is the only text a profile adds to the context. `/profile show` prints
it verbatim, so you can check that it does not fight your own system prompt or
`CLAUDE.md`. Dev adds nothing at all.

The status line shows any profile other than dev, so a creative switch you
forgot about is visible in the next coding session:

```text
Opus 5.5 | high | [####......] 64k/150k 43% | routine | creative | 5h 21% | 7d 9%
```

**What it does not do.** A profile does not change the model, the session's
effort level, or the context ceilings. `/profile` is marked user-invoked only, so
Claude does not trigger it on its own; you decide when the session switches.

**Where the choice lives.** `"profile"` in `~/.claude/tuner.config.json`. The
switch edits that one key and leaves the rest of the file, and its formatting,
alone. A misspelt name falls back to dev and is reported at session start and by
`doctor.ps1`.

**Customising a profile.** The active profile is applied after your top-level
settings, so switching always changes behaviour. To change what a profile does,
override it under `profiles`:

```json
{
  "profile": "creative",
  "profiles": {
    "creative": { "routineTokens": 180000, "maxTurnsPerSession": 1 }
  }
}
```

Every key is listed in [docs/configuration.md](docs/configuration.md#profiles).

**Limits.** Profiles need the hooks, so they work wherever Claude Code runs them
(the terminal, the VS Code panel and the Desktop app) but not with `-NoHooks`
or the portable `claude-skill`. Upgrading from 0.4.x: pull and re-run the installer with
`-Force`, which replaces the installed skill folders (backing them up first),
then restart Claude Code.

## Install

**Requirements:** Claude Code 2.1 or newer. Windows 10/11 needs nothing extra —
Windows PowerShell 5.1 is built in. macOS and Linux need **PowerShell 7
(`pwsh`)**, because that is what Claude Code runs the hooks with. No admin
rights, no modules.

### Windows

```powershell
git clone https://github.com/YahyaLendani/opus-tuner-claude-skill.git
cd opus-tuner-claude-skill
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

### macOS / Linux

```sh
git clone https://github.com/YahyaLendani/opus-tuner-claude-skill.git
cd opus-tuner-claude-skill
./install.sh
```

`install.sh` is a thin wrapper: it checks for `pwsh`, prints the install command
for your OS if it is missing, then runs `install.ps1` with every switch passed
through (`./install.sh -Force`, `./install.sh -NoHooks`, ...).

```sh
# macOS
brew install --cask powershell
# Ubuntu / Debian
snap install powershell --classic
```

### The installer does

- copy seven skills into `~/.claude/skills/` (or `$CLAUDE_CONFIG_DIR`): the
  hook-free `claude-skill` only with `-NoHooks`, the `profile` switch only with
  hooks, since every installed skill's description costs context on every
  request. A leftover from the other mode, or from 0.5.0, is moved to the backups;
- merge six hook events into `~/.claude/settings.json`, **keeping your existing
  hooks** and backing the file up first;
- add a status line, unless you already have one;
- append a marked token-discipline block to `~/.claude/CLAUDE.md`.

It is idempotent: running it again does not duplicate entries. Use `-Force` to
replace existing skill folders and an existing status line (both are backed up).
`-DryRun` prints the merged settings without writing.

Then restart Claude Code — or **Developer: Reload Window** in VS Code, which
reads hook config at session start.

```powershell
# optional: also register the PreToolUse read guard
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Force -Enforce
```

### No hooks, or no Claude Code

Hooks only exist in Claude Code. Two fallbacks:

| Situation | Use |
|---|---|
| Claude Code, but hooks are blocked by policy | `install.ps1 -NoHooks` (or `./install.sh -NoHooks`): skills and the `CLAUDE.md` block, nothing in `settings.json`. |
| Desktop app or claude.ai | The [`claude-skill`](skills/claude-skill/SKILL.md) skill: the same discipline as a self-contained, advisory SKILL.md. Upload the folder where your client supports skills, or paste its body into project instructions. |

`-NoHooks` is advisory by design: no ceilings are enforced, no state is written.
`doctor.ps1` says so if it finds no hooks.

## Verify

```powershell
# Windows
# 88 assertions: routing, hard wrap, compaction, handoff round trip, profiles, automatic savings, audit, timing
# (87 if ~/.claude/settings.json does not exist yet — the matcher check is skipped)
powershell -NoProfile -File skills\opus-tuner\scripts\selftest.ps1

# 59 assertions: install/upgrade/uninstall, -NoHooks, hook shape, replay, advisory, version, future model, against a sandbox
powershell -NoProfile -File tests\install-test.ps1

# every relative Markdown link points at a file that exists (no network)
powershell -NoProfile -File tests\link-check.ps1

# every badge in this README renders (network; CI reports it without blocking)
powershell -NoProfile -File tests\badge-check.ps1

# is the install healthy? hooks registered, scripts present, config valid
powershell -NoProfile -File skills\opus-tuner\scripts\doctor.ps1

# prove the registered command strings actually run (all six events, ~3 s)
powershell -NoProfile -File skills\opus-tuner\scripts\doctor.ps1 -Replay

# skills only: check this copy without requiring hooks (implied when none are registered)
powershell -NoProfile -File skills\opus-tuner\scripts\doctor.ps1 -SkillsOnly
```

```sh
# macOS / Linux — same scripts, same counts
pwsh -NoProfile -File skills/opus-tuner/scripts/selftest.ps1
pwsh -NoProfile -File tests/install-test.ps1
pwsh -NoProfile -File skills/opus-tuner/scripts/doctor.ps1
pwsh -NoProfile -File skills/opus-tuner/scripts/doctor.ps1 -Replay
```

`selftest.ps1` picks `pwsh` when it is on `PATH`, otherwise `powershell`. Pass
`-Interpreter powershell` to force 5.1 on Windows, or `-BudgetMs 3000` on a busy
CI runner. The timing gate charges the interpreter's own start to the platform:
a no-op script is timed three times, the minimum is subtracted, and the budget
applies to the hook's own cost — so a cold shared runner does not fail the build
for a hook whose real work is ~20 ms. `doctor.ps1` exits non-zero when something
is broken, so it works as a post-install gate.

`doctor.ps1` alone proves the hooks are *registered* and their scripts exist.
`-Replay` goes further: it runs each registered command exactly as written, in a
throwaway config dir, and asserts exit 0 plus empty-or-valid-JSON output. That is
what catches a quoting error in the command string or a shell that cannot start
the interpreter — failures that look identical to "no hooks" at runtime.

A copy with no registered hooks is reported as an **advisory install** and exits
0: the skills, config and scripts are checked, the six wiring checks are shown as
`skip`, and nothing is written to the state directory. A *partial* wiring (some
events registered, others not) still fails, because that is a broken install
rather than a deliberate one. `-SkillsOnly` forces the same view when hooks do
exist but you only want to validate the skills.

In Claude Code, `/hooks` should list `UserPromptSubmit`, `PostToolUse`,
`PostToolUseFailure`, `Stop`, `SessionStart`, `PreCompact`; `/skills` should list
`opus-tuner`, `gear-low`, `gear-medium`, `gear-xhigh`, `gear-max`, `wrap`,
`profile`. With `-NoHooks`, `/hooks` is empty and that is expected, and `/skills`
shows `claude-skill` instead of `profile`.

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

The dev / creative switch is covered in
[Dev and creative profiles](#dev-and-creative-profiles) above.

## Measure

```powershell
# Windows
# per-session tokens and API-equivalent cost, newest 20 sessions
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20

# compare against a CSV captured before tuning
powershell -NoProfile -File skills\opus-tuner\scripts\audit.ps1 -Recent 20 -Baseline baseline.csv

# what the router decided, last 7 days
powershell -NoProfile -File skills\opus-tuner\scripts\stats.ps1 -Days 7

# both of the above against the newest baseline, written to state/tuner/weekly-<date>.txt
powershell -NoProfile -File skills\opus-tuner\scripts\weekly.ps1
```

```sh
# macOS / Linux
pwsh -NoProfile -File skills/opus-tuner/scripts/audit.ps1 -Recent 20
pwsh -NoProfile -File skills/opus-tuner/scripts/audit.ps1 -Recent 20 -Baseline baseline.csv
pwsh -NoProfile -File skills/opus-tuner/scripts/stats.ps1 -Days 7
pwsh -NoProfile -File skills/opus-tuner/scripts/weekly.ps1
```

Take a baseline **before** tuning (`audit.ps1 -Csv baseline.csv`), then pass it
back with `-Baseline` after a week: the report prints peak context, cache read and
cost per request as a before/after table. Peak context should fall first; cost per
request falls last, because cache write and output do not scale with context the
way cache read does. [docs/measuring.md](docs/measuring.md) explains the method
and the traps.

## Uninstall

```powershell
# Windows, from the clone
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

```sh
# macOS / Linux, from the clone
pwsh -NoProfile -File uninstall.ps1
```

Removes its hooks, its status line, its `CLAUDE.md` block, and its skill folders.
Your own hooks and settings stay. `-KeepSkills` keeps the folders; `-Purge` also
deletes `tuner.config.json` and the session state. Removing the skills alone is
not enough if hooks remain: they would fire against missing scripts, so run the
uninstaller rather than deleting folders by hand.

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
| [docs/platforms.md](docs/platforms.md) | Windows, macOS, Linux, terminal vs VS Code vs Desktop, `pwsh` install, `-NoHooks` |
| [docs/architecture.md](docs/architecture.md) | Hook lifecycle, state schema, concurrency, latency budget |
| [docs/configuration.md](docs/configuration.md) | Every knob, modes, enforce setup, tuning guidance |
| [docs/measuring.md](docs/measuring.md) | How `audit.ps1` counts, how to capture a baseline |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Hooks not firing, `pwsh` missing, VS Code quirks, quota questions |
| [docs/decisions.md](docs/decisions.md) | Why the design is shaped this way |
| [SECURITY.md](SECURITY.md) | Trust boundary, what the scripts read and write, how to report a vulnerability |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | What is expected here, and the one private channel for reporting a problem |
| [skills/opus-tuner/README.md](skills/opus-tuner/README.md) | Technical reference for the installed skill |
| [skills/claude-skill/SKILL.md](skills/claude-skill/SKILL.md) | Portable, hook-free version for Desktop and claude.ai |

## License

MIT. See [LICENSE](LICENSE).
