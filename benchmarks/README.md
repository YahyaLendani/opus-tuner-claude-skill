# Benchmarks

**Status: PENDING. No live evaluation has been recorded.** Nothing in this repository
shows that opus-tuner saves tokens, money or time compared with default Claude Code or
with a short instruction file. This directory is the means to find out. So far it has
only run against a stand-in that never calls a model, which tests the harness and says
nothing about the arms.

## What it compares

The same tasks, model, effort, tools, permissions and budgets under each arm. `arms.json`
holds the only differences.

| Arm | Setup | How work continues after the first phase |
|---|---|---|
| `default` | Empty configuration | Stays in one session, with native auto-compaction |
| `short` | Empty configuration plus [short-instructions.md](short-instructions.md) | Writes `HANDOFF.md`, then a new session reads it |
| `tuner` | `install.ps1` into the empty configuration, assist mode | `/wrap`, then a new session |
| `tuner-monitor` (optional) | Monitor mode | Stays in one session. Shows what the hooks alone add |
| `tuner-no-routing` (optional) | Assist mode with `downshift` off | Separates automatic effort routing from the rest |
| `tuner-guard` (optional) | Guard mode with `hardWrap` and `blockManualCompact` on | Shows what the interruptions add |

Every task has the same shape: work, continuation, a recall question, more work, then
grading. The first phase sets rules and decisions that the later prompt does not repeat.

| Task | What it does |
|---|---|
| `ledger-rules` | A bug fix, then a feature that has to follow rules set earlier |
| `timeout-migration` | A six-module migration in two phases, with a directory that must not be edited |
| `record-sweep` | Reads 40 files, enough to pass the routine context ceiling, then edits what it found. The most expensive task |

## What it measures

| Measure | How |
|---|---|
| Correct completion | The task's `check.ps1`, which never sees the session. The workspace is graded even when a run fails |
| Tokens and cost | `audit.ps1` over the run's own transcripts, after every step, so each step has its own share. Costs are API-equivalent estimates, not billing |
| Elapsed time | Wall clock for each step |
| Interruptions | Handoff continuations, Stop prompts, blocked compactions, denied permissions |
| Information lost | A recall step asks for facts from the first phase, matched by each task's patterns |
| Repeated work | Reads and searches after the continuation that had been made before it. A proxy: some repeats are sensible |
| Handoff and rebuild cost | The handoff step and the first step afterwards, shown separately and also included in the totals |

Failed runs, wrong results, lost facts and handoffs that were not verified or not picked
up are listed in the report beside the successes.

## Running it

See the plan, calling nothing:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks/run.ps1
```

Test the harness offline. This is what CI does:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests/benchmark-test.ps1
```

A live run spends real money, so it refuses to start without `-AllowLive`, a full model
id, the pinned Claude Code version, both budgets and `ANTHROPIC_API_KEY`. The key is passed
through to Claude Code and never written down. Your saved login and `~/.claude` are not
used: each run gets its own empty `CLAUDE_CONFIG_DIR` and a fresh workspace.

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks/run.ps1 -AllowLive -Model claude-sonnet-5-5 -ExpectVersion 2.1.314 -MaxRunUsd 5 -MaxTotalUsd 60 -Repeats 5
```

Add `-Tasks ledger-rules` for a cheaper first run, and `-Arms default,short,tuner,tuner-no-routing,tuner-guard` to get evidence on routing and blocking. Then:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks/report.ps1
```

Results go to `benchmarks/results/<time>/`, which git ignores: `manifest.json` (versions,
model, seed, flags), `runs.jsonl` (one line per run), `report.md` and `summary.json`.

## Checked against the real CLI

On Claude Code 2.1.314 on Windows, with an invalid API key, so nothing reached a model:

- The CLI accepted every flag the harness passes, and the failed runs were recorded and reported.
- The tuner's hooks fired in print mode under an isolated `CLAUDE_CONFIG_DIR`, with the right
  session id. The `default` arm got no tuner files.
- A verified handoff was marked `.ended` when its session exited, and the next new session
  took it through the startup path, with its text in that session's context.

Still unproven, because they need a working model: `/wrap` driven by the model, real usage
figures flowing through the audit, and `--max-budget-usd` stopping a real step.

## Limits of a run

- **Print mode has no `/clear`.** After a handoff the harness starts a new session, which
  takes the startup path in `session-start.ps1` instead of the `/clear` path. Whether the
  hook picked the handoff up is recorded for each run. A run where it did not is listed as
  a failure and counts against the arm.
- **No person is involved.** Interruptions are counted, but what they cost a person, and
  how a person would answer them, is not measured.
- **The budget can be passed by one step.** `--max-budget-usd` and the checks between steps
  and runs stop further spending. They cannot take back the step that crossed the line.
- **Grading is by rule, on synthetic tasks,** on one setup. It does not show what happens on
  your own work, or what a subscription would charge.
- **Ranges are only comparable with enough runs.** The report warns under five repeats and
  says only whether the observed ranges are apart.

## What the results are for

Whether automatic effort routing and compaction blocking justify their maintenance and
execution overhead is undecided until a live run has been recorded. Compare `tuner` with
`tuner-no-routing` for the first, and with `tuner-guard` for the second.
