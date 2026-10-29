# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.5.0] - 2026-10-29

Two profiles, and four fixes for behaviour that did not match the docs.

### Added

- `/profile` swaps between **dev** (the default, unchanged) and **creative**.
  Creative turns off the `gear-low` downshift and `gear-max`, escalates the deep
  tier on long-form vocabulary, and adds one note at session start. `/profile
  show` prints the active settings and the exact note, so it can be checked
  against your own system prompt. Stored as `"profile"` in `tuner.config.json`;
  the switch edits that key only.
- `downshift` and `profiles` config keys. A misspelt profile falls back to dev
  and is reported at session start and by `doctor.ps1`.
- The status line shows the profile when it is not dev.

### Fixed

- The `opus-tuner` skill told the model to delegate to `scout` and `hand`
  subagents that the bundle never shipped. It now names the built-in `Explore`
  agent and a general-purpose one.
- When the prompt hook saw the ceiling before the Stop hook did, it set the
  Stop hook's banner flag, so the user never saw the "/wrap then /clear"
  banner. Each hook now has its own flag.
- A compaction reset the session state, which re-armed the "once per session"
  `/compact` refusal and refilled the `gear-max` ration. Both now survive it.
- `mode: off` still let the tool hook write state files on every edit and
  failure. It is now silent, as documented.
- `uninstall.ps1` deleted any skill folder named `wrap`, including a user's own.
  It now removes `wrap` and `profile` only when they are recognisably ours.

### Notes

- Self-test: 73 assertions (was 57). It now runs against an empty config of its
  own, so a live install's profile or ceilings cannot change the result.
  Installer test: 56 assertions, now expecting eight skills.

## [0.4.1] - 2026-10-28

The doctor stops trusting one model name.

### Fixed

- `doctor.ps1` validated `modelSettings` only when the key was literally
  `claude-opus-5-5`. On any other model name the check disappeared, so an invalid
  `effortLevel` sat in `settings.json` while the doctor reported healthy — the
  exact failure the check exists to prevent. It now validates every entry under
  `modelSettings` and names the offender: `invalid: claude-opus-6=extreme`.
- The README H1 rendered literal `**` around `claude-skills`.

### Added

- `tests/link-check.ps1` fails when a relative Markdown link points at a file
  that does not exist. Fenced code blocks and anchors are skipped. It is
  deterministic, so CI runs it blocking on Windows and POSIX.
- `tests/badge-check.ps1` fetches every badge in the README and fails when one
  renders "no releases", "not found" or similar. CI runs it with
  `continue-on-error`, because a shields.io outage must not fail a pull request.
- CI cancels superseded runs (`concurrency`) and each job has a 15-minute
  timeout, so a hung interpreter cannot burn the default six hours.

### Notes

- Self-test: 57 assertions. Installer test: 56 assertions (was 55), now covering
  a model name the bundle has never heard of.

## [0.4.0] - 2026-10-28

The version is now something the code knows, not a number kept in prose.

### Added

- `skills/opus-tuner/VERSION` — the single source of truth, installed with the
  skill so an installed copy can answer "which build is this?" without the repo.
- `doctor.ps1` prints `opus-tuner <version>` above its sections and reports it as
  `version` in `-Json`. `install.ps1` and `uninstall.ps1` print it in their
  banner. `SECURITY.md` asks reporters for the version; until now nothing could
  produce one.
- A CI step fails the build when `VERSION`, the README status line and the top
  `CHANGELOG.md` heading disagree. The version cannot drift silently.
- `v0.4.0` tag and GitHub Release, so installs can be pinned instead of tracking
  `main`. The README version badge now reads the latest release.
- `docs/platforms.md` documents uninstalling on macOS and Linux, where there is no
  `uninstall.sh` and `pwsh` is required.
- `docs/troubleshooting.md` answers "which version is installed?".

### Changed

- `SECURITY.md` is linked from the README documentation table.

### Notes

- Self-test: 57 assertions. Installer test: 55 assertions (was 53), now covering
  the installed `VERSION` file and the doctor's version output.

## [0.3.2] - 2026-10-28

The doctor stops crying wolf on a skills-only install.

### Added

- `doctor.ps1 -SkillsOnly`, and automatic advisory detection: when
  `settings.json` registers no opus-tuner hooks, the six wiring checks are
  reported as `skip` instead of failing, the state-directory probe is skipped so
  no folder is created, and the exit code is 0 with an explicit
  `advisory install` line. A partial wiring (some events registered, others
  missing) still fails — that is a broken install, not a deliberate one.
- `doctor.ps1` run from a vendored copy (`<root>/skills/opus-tuner/scripts`) now
  inspects that copy instead of `~/.claude`. The installed copy derives
  `~/.claude`, so nothing changes there; `-Root` and `CLAUDE_CONFIG_DIR` still
  take precedence.
- `-Json` reports `advisory` and `skipped` alongside `ok` and `failed`.

### Fixed

- The self-test timing gate charged the interpreter's cold start to the hooks, so
  a shared macOS runner failed at 3120 ms against a 3000 ms budget for a hook
  whose own work is ~20 ms. It now times a no-op script three times, subtracts
  the minimum, and gates on the hook's own cost; the report prints both numbers.

### Notes

- Self-test: 57 assertions. Installer test: 53 assertions (was 50), now covering
  the advisory install, the absence of a created state directory, and the
  partial-wiring boundary.

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

- Verified live on Claude Code 2.1.267, not only replayed: all six events fire.
  `SessionStart` (`startup` and `resume`), `UserPromptSubmit`, `PostToolUse`
  (`Write`), `PostToolUseFailure` (`Bash`, recorded as `fails: 1`), `Stop`, and
  `PreCompact` (manual `/compact` refused once and logged as `compact-blocked`
  at `ctx=27646`, `tier=routine`, `gear=high`).
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

[0.4.1]: https://github.com/YahyaLendani/opus-tuner/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/YahyaLendani/opus-tuner/releases/tag/v0.4.0

<!-- Entries below 0.4.0 predate tagging, so their headings are plain text: a
     compare link to a tag that does not exist would be worse than none. -->
