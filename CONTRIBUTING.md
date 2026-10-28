# Contributing

Thanks for taking the time. This project is intentionally small: a handful of
PowerShell scripts, no dependencies, and a test suite that must stay green.

## Ground rules

- **Windows PowerShell 5.1 must keep working.** That is the supported runtime.
  Do not use `??`, `-Parallel`, ternary `? :`, or other PowerShell 7-only syntax.
- **No dependencies.** Standard library and Windows built-ins only. Do not add
  modules, Pester, npm, or a build step.
- **No network calls.** This tool exists to be auditable.
- **Fail open.** A hook that throws must still exit 0, or it can strand a
  session. Wrap hook bodies in `try { } catch { }`.
- **Zero tokens when idle.** Anything injected into the model's context must
  justify its cost. Banners go to `systemMessage`, not `additionalContext`.

## Layout

```
skills/opus-tuner/scripts/   hooks and the CLI scripts
skills/opus-tuner/           SKILL.md + reference docs
skills/gear-*/               one-turn effort skills
skills/wrap/                 the handoff skill
tests/                       installer integration test
install.ps1 / uninstall.ps1
```

`skills/` mirrors the install target, so a cloned repo can be installed with one
command and the paths in `settings.json` stay relative to the config dir.

## Before opening a PR

Run both suites from the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\opus-tuner\scripts\selftest.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install-test.ps1
```

Both must pass with 0 failures. The self-test is sandboxed through
`OPUS_TUNER_STATE`; the installer test uses a throwaway `CLAUDE_CONFIG_DIR`. If
you add a hook or a config key, add an assertion for it.

Also check that every script still parses:

```powershell
Get-ChildItem skills\opus-tuner\scripts\*.ps1 | ForEach-Object {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e) { "$($_.Name): $($e[0].Message)" }
}
```

## Style

- 4 spaces, no tabs. Keep functions small and allocation-light: these run on
  every prompt and every tool call.
- Comments explain *why*, not *what*. If a line encodes a measurement or a
  platform quirk, say so and give the number.
- Do not add a knob without a default that preserves current behaviour.
- Update `CHANGELOG.md` for user-visible changes.

## Commit messages

`area: what changed and why`, for example:

```
stop: block once at the ceiling instead of warning
```

Please keep a commit to one idea. Include the measurement or reproduction in the
body when the change is about performance.
