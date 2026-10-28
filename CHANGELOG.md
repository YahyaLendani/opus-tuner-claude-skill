# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-10-28

Visibility, diagnosis, and measurement. The bundle could already prevent a large
context; it could not see compaction, could not diagnose a broken install without
a hand-written checklist, and could not compare two weeks of numbers.

### Added

- `PreCompact` hook (`pre-compact.ps1`): every compaction is logged with its
  context size (`compact-manual`, `compact-auto`, `compact-blocked`), and the first
  manual `/compact` per session is refused once with a pointer to `/wrap` +
  `/clear`. Automatic compaction is never blocked — when it is recovering from a
  context-limit error, blocking it fails the request.
- `doctor.ps1`: one-command install health check. Verifies that the hooks are
  registered and their scripts exist, that `settings.json` and the tuner config
  parse, that `routineTokens < deepTokens < autoCompactWindow`, that all six
  skills are installed with matching `name:` frontmatter, that every script
  parses, and that the state directory is writable. `-Json` and `-Root <dir>`;
  exit code 1 when anything fails.
- Resume cost warning: on `resume`/`fork`, `SessionStart` reports the context size
  and the estimated cost of the first request at Opus cache-read rates.
- `audit.ps1 -Baseline <csv>`: prints a before/after table for sessions, requests,
  cache read, median peak context, cost, and cost per request.
- Malformed-config warning: a `tuner.config.json` that does not parse used to fall
  back to defaults silently; `SessionStart` now says so once.

### Changed

- `SessionStart` emits a single JSON object carrying both the free warnings
  (`systemMessage`, 0 model tokens) and the handoff brief.
- The self-test's latency budget default is 750 ms (was 500 ms); measured
  blocking hooks are 440–490 ms on a loaded machine, and CI passes
  `-BudgetMs 3000`.
- New config key `blockManualCompact` (default `true`); `false` keeps the logging
  and drops the block.

### Notes

- Self-test: 57 assertions (56 without a `settings.json` to inspect). Installer
  test: 43 assertions, now covering the `PreCompact` wiring and `doctor.ps1`.

## [0.1.0] - 2026-10-28

First public release.

### Added

- Tiered context ceilings (routine / deep) with a grace band that escalates
  instead of cutting a task off.
- `Stop` hook hard wrap: one `decision: "block"` per ceiling crossing, so the
  handoff brief is written before the session continues.
- Effort gears (`low` / `medium` / `xhigh` / `max`) with an escalate-only router.
- `/wrap` handoff writer and `SessionStart` re-seed, as an alternative to
  `/compact`.
- `audit.ps1` per-session token and cost report, `stats.ps1` decision summary,
  and a CSV decision log.
- `install.ps1` / `uninstall.ps1` with idempotent `settings.json` merging and
  timestamped backups.
- Self-test (45 assertions; 44 when no `settings.json` exists to inspect) and
  installer test (38 assertions), both sandboxed.
- GitHub Actions workflow running both suites on Windows.

### Notes

- Windows PowerShell 5.1 is the supported runtime. `pwsh` 7 works but was
  measured slower on the development machine; see the latency section.
- Hooks fail open: any error exits 0 and lets Claude Code continue.
