# Security

## What this project is

opus-tuner is a set of local PowerShell scripts wired into Claude Code hooks. It
runs with your user privileges, exactly like any other hook you configure.

## What it does not do

- No network calls, telemetry, or update checks.
- No API keys, tokens, or credentials.
- No third-party binaries or packages.
- It never runs `/clear`, `/compact`, or any slash command. Clearing the session is
  always your action, and no hook can block it.
- A handoff omits raw command arguments unless `-IncludeCommandArgs` is passed, and
  masks credential-shaped values before saving anything.

## Trust boundary

`settings.json` is executable configuration. A hook entry can run any command, so
treat changes to it the way you treat changes to a shell profile. The installer
merges entries instead of replacing the file, backs it up first, and only adds
commands that point inside the installed skill directory.

The scripts read:

- `~/.claude/settings.json` (installation only)
- `~/.claude/tuner.config.json` (configuration)
- `~/.claude/state/tuner/` (session state and the decision log)
- the current session's transcript under `~/.claude/projects/` (read-only)

They write only under `~/.claude/state/tuner/`, which includes the per-session
handoffs in `handoffs/`, plus `tuner.config.json`, `CLAUDE.md` and the settings file
during install/uninstall, each backed up first. A handoff holds a summary of your
session, so treat that folder like the transcripts themselves.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository
("Security" tab -> "Report a vulnerability"). Please do not open a public issue
for anything that could execute code, leak transcript contents, or modify files
outside the paths listed above.

Include the version, the PowerShell version, and a minimal reproduction.
