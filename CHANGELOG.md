# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.3.1] - 2026-10-28

Proof of wiring, without waiting for a prompt.

### Added

- `doctor.ps1 -Replay`: executes each registered hook command exactly as written
  in `settings.json`, in a throwaway config dir, and asserts exit 0 plus
  empty-or-valid-JSON output. Registration plus a script that parses is not the
  same as a hook that runs: a quoting error in the command string, or a shell
  that cannot start the interpreter, fails only at invocation time and looks
  identical to "no hooks". The installer test now covers both the passing replay
  and a deliberately broken command.
- `weekly.ps1`: finds the newest `baseline-*.csv`, runs `audit.ps1 -Baseline` and
  `stats.ps1 -Days 7`, and writes the combined report to
  `state/tuner/weekly-YYYY-MM-DD.txt`. `-Days`, `-Recent`, `-Baseline` and
  `-NoFile` adjust it. Removes the need to remember two commands a week later.

### Notes

- Self-test: 57 assertions. Installer test: 50 assertions (was 48).
- Found while adding this: a local `$json` in a script with a `[switch]$Json`
  parameter is the same variable, so assigning a string to it throws a
  `SwitchParameter` conversion error. Noted in `CONTRIBUTING.md`.

## [0.3.0] - 2026-10-28

Reach. The bundle was correct but Windows-only, VS Code-shaped, and useless
outside Claude Code. This release keeps one codebase and widens who can run it.

### Added

- **macOS and Linux support.** The scripts now resolve the home directory and
  join paths portably, so the same hooks run under `pwsh` 7. The installer emits
  `pwsh -NoProfile -File "<path>"` with `"shell": "bash"` on POSIX and omits
  `-ExecutionPolicy`, which `pwsh` rejects. `_common.ps1` exposes
  `$script:OnWindows` and `$script:HomeDir`.
- `install.sh`: a POSIX wrapper that checks for `pwsh`, prints the install
  command for the OS when it is missing, and passes every switch through.
- `skills/claude-skill/SKILL.md`: a self-contained advisory skill for Claude
  Desktop and claude.ai, where hooks do not exist. Same ceilings, rules, handoff
  template and resume procedure, stated as prose with its limits spelled out.
- `install.ps1 -NoHooks`: skills and the `CLAUDE.md` block only, for machines
  where `settings.json` cannot be modified. It never reads or writes settings.
- `doctor.ps1` checks that `pwsh` is on `PATH` on POSIX, where a missing runtime
  is the most likely reason nothing fires.
- `.gitattributes` pins `*.sh` to LF: a CRLF shebang does not run.
- `docs/platforms.md`: the client/platform matrix, per-OS install, advisory mode,
  file locations, CI matrix and known limits.

### Changed

- The installer writes platform-appropriate line endings for `CLAUDE.md` and
  normalises the embedded block, instead of hard-coding CRLF.
- The installer and uninstaller handle seven skills (was six).
- `selftest.ps1` and `tests/install-test.ps1` are portable: they build an
  `$ExePrefix` (no `-ExecutionPolicy` off Windows), use
  `[System.IO.Path]::GetTempPath()`, and run child scripts with the interpreter
  that is running the test. The installer test asserts the platform's hook shape.
- CI runs three jobs: Windows PowerShell 5.1 (blocking), Windows `pwsh` 7
  (non-blocking, timing variance), and Ubuntu + macOS `pwsh` 7 (blocking). The
  POSIX job also executes `install.sh` under `bash` against a temporary
  `CLAUDE_CONFIG_DIR`.
- README and troubleshooting no longer assume Windows or VS Code; commands are
  given for both interpreters.

### Notes

- Self-test: 57 assertions (56 without a `settings.json` to inspect). Installer
  test: 48 assertions, now covering `-NoHooks` and the platform hook shape.
- The POSIX path is validated by CI only; the development machine deliberately
  has no `pwsh`.
- The repository language bar may now include Shell from `install.sh`. That is
  expected and is not suppressed.

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
