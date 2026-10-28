# Security

## What this project is

opus-tuner is a set of local PowerShell scripts wired into Claude Code hooks. It
runs with your user privileges, exactly like any other hook you configure.

## What it does not do

- No network calls, telemetry, or update checks.
- No API keys, tokens, or credentials.
- No third-party binaries or packages.
- It never runs `/clear`, `/compact`, or any slash command. The hard wrap asks the
  model to write a brief; clearing the session remains your action.

## Trust boundary

`settings.json` is executable configuration. A hook entry can run any command, so
treat changes to it the way you treat changes to a shell profile. The installer
merges entries instead of replacing the file, backs it up first, and only adds
commands that point inside the installed skill directory.

The scripts read:

- `~/.claude/settings.json` (installation only)
- `~/.claude/tuner.config.json` (configuration)
- `~/.claude/state/tuner/` (session state and the decision log)
- the current transcript tail under `~/.claude/projects/` (read-only, last 512 KB)
- the project's `.claude/handoff.md` (handoff)

They write only under `~/.claude/state/tuner/`, the handoff file, and the settings
file during install/uninstall.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository
("Security" tab -> "Report a vulnerability"). Please do not open a public issue
for anything that could execute code, leak transcript contents, or modify files
outside the paths listed above.

Include the version, the PowerShell version, and a minimal reproduction.
