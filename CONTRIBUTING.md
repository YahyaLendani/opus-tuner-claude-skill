# Contributing

Thanks for taking the time. This project is intentionally small: a handful of
PowerShell scripts, no dependencies, and a test suite that must stay green.

## Ground rules

- **Windows PowerShell 5.1 must keep working.** It is the default runtime on
  Windows and the job that blocks CI. Do not use `??`, `-Parallel`, ternary
  `? :`, or other PowerShell 7-only syntax.
- **`pwsh` 7 must keep working too.** macOS and Linux run the same scripts under
  PowerShell 7. Use `$script:OnWindows` and `$script:HomeDir` from `_common.ps1`
  instead of `$env:USERPROFILE`, and never write a backslash path literal: nest
  `Join-Path` calls (`Join-Path (Join-Path $root 'state') 'tuner'`). A single
  `'state\tuner'` is one filename on POSIX.
- **No dependencies.** Standard library and Windows built-ins only. Do not add
  modules, Pester, npm, or a build step. `pwsh` is the one runtime prerequisite,
  and only outside Windows.
- **No network calls.** This tool exists to be auditable.
- **Fail open.** A hook that throws must still exit 0, or it can strand a
  session. Wrap hook bodies in `try { } catch { }`.
- **Zero tokens when idle.** Anything injected into the model's context must
  justify its cost. Banners go to `systemMessage`, not `additionalContext`.
- **`-ExecutionPolicy` is Windows-only.** Never pass it to `pwsh` on macOS or
  Linux; it fails before the script runs. Build an `$ExePrefix` the way
  `selftest.ps1` does.

## Layout

```
skills/opus-tuner/scripts/   hooks and the CLI scripts
skills/opus-tuner/           SKILL.md + reference docs
skills/claude-skill/         portable, hook-free skill for Desktop / claude.ai
skills/gear-*/               one-turn effort skills
skills/wrap/                 the handoff skill
tests/                       installer integration test
install.ps1 / uninstall.ps1
install.sh                   POSIX wrapper around install.ps1
```

`skills/` mirrors the install target, so a cloned repo can be installed with one
command and the paths in `settings.json` stay relative to the config dir.

## Before opening a PR

Run both suites from the repo root. On Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\opus-tuner\scripts\selftest.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install-test.ps1
```

On macOS or Linux, the same scripts with `pwsh`:

```sh
pwsh -NoProfile -File skills/opus-tuner/scripts/selftest.ps1
pwsh -NoProfile -File tests/install-test.ps1
```

Both must pass with 0 failures (currently 57 and 56 assertions). The self-test is
sandboxed through `OPUS_TUNER_STATE`; the installer test uses a throwaway
`CLAUDE_CONFIG_DIR`. If you add a hook or a config key, add an assertion for it,
and update the expected counts in `README.md` and `CHANGELOG.md` when they change.

`selftest.ps1` also exercises the Windows 5.1 path and the `pwsh` path when both
are present: pass `-Interpreter powershell` or `-Interpreter pwsh` to pick one.

If a suite fails and the cause is not obvious, `doctor.ps1` names the broken link
in a live install:

```powershell
# Windows
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\doctor.ps1"
```

```sh
# macOS / Linux
pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/doctor.ps1"
```

Also check that every script still parses (works on either interpreter):

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e) { "$($_.Name): $($e[0].Message)" }
}
```

## CI

`.github/workflows/test.yml` runs three jobs:

| Job | What it proves | Blocking |
|---|---|---|
| `windows-powershell-51` | parse, self-test, installer test on 5.1 | yes |
| `windows-pwsh-7` | the same on `pwsh` 7 | no — startup timing varies |
| `posix` (Ubuntu + macOS) | parse, self-test, installer test, and `install.sh` under `bash` | yes |

The POSIX job is the only place `install.sh` is executed. It asserts that the
file is executable, that the shebang survives checkout (`.gitattributes` pins
`*.sh` to LF), and that `-NoHooks` writes skills and `CLAUDE.md` but no
`settings.json`. If you change the installer's switches, update that step.

`tests/link-check.ps1` runs blocking on both Windows and POSIX: it is local and
deterministic. `tests/badge-check.ps1` runs on Windows with `continue-on-error`,
because it fetches shields.io and a third-party outage must not fail a pull
request. Run both before touching the README.

## Releasing

1. Bump `skills/opus-tuner/VERSION`, add the `CHANGELOG.md` entry, and update the
   `> **Status:**` line in `README.md` to the same number.
2. Push and wait for CI. The `Version is consistent` step fails if the three
   disagree, so a forgotten bump cannot reach a tag.
3. Tag and publish, replacing `vX.Y.Z` with the version in `VERSION`:
   ```sh
   git tag -a vX.Y.Z -m "opus-tuner X.Y.Z"
   git push origin vX.Y.Z
   gh release create vX.Y.Z --title "opus-tuner X.Y.Z" --generate-notes
   ```
4. The README version badge reads the latest release through shields.io, so there
   is nothing to edit. A release is what makes the badge say a number.

## Style

- 4 spaces, no tabs. Keep functions small and allocation-light: these run on
  every prompt and every tool call.
- Comments explain *why*, not *what*. If a line encodes a measurement or a
  platform quirk, say so and give the number.
- Do not add a knob without a default that preserves current behaviour.
- Update `CHANGELOG.md` for user-visible changes.
- `skills/opus-tuner/VERSION` is the single source of truth for the version. A
  release bumps that file, adds the `CHANGELOG.md` entry, and updates the README
  status line — CI compares all three and fails on a mismatch, so this is enforced
  rather than remembered. The other badges are live: CI, release, license and the
  language split come from GitHub and cannot drift.
- **Never name a local `$json` in a script that has a `-Json` switch.** PowerShell
  variables are case-insensitive, so `$json` *is* `$Json`, and assigning a string
  to a `[switch]` throws a `SwitchParameter` conversion error. The same trap
  applies to `$root`/`$Root`, `$force`/`$Force`, and the other switch names.

## Commit messages

`area: what changed and why`, for example:

```
stop: block once at the ceiling instead of warning
```

Please keep a commit to one idea. Include the measurement or reproduction in the
body when the change is about performance.
