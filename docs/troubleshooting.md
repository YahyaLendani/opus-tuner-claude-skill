# Troubleshooting

## Hooks do not fire

0. **Run the doctor.** It checks the whole wiring in one command:

   ```powershell
   # Windows
   powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\doctor.ps1"
   ```

   ```sh
   # macOS / Linux
   pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/doctor.ps1"
   ```

   Exit code 0 means healthy. It names the specific break: a hook pointing at a
   missing script, a config that does not parse, a skill folder without a matching
   `name:`, an unwritable state directory, or — on POSIX — a missing `pwsh`.

   If the doctor is healthy but nothing fires, add `-Replay`. It executes each
   registered command exactly as written, which is the only way to catch a
   quoting error in the command string or a shell that cannot start the
   interpreter:

   ```powershell
   powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\doctor.ps1" -Replay
   ```

1. **Reload.** Claude Code reads hook configuration at session start. Restart it,
   or use *Developer: Reload Window* in VS Code.
2. Check `/hooks`. You should see `UserPromptSubmit`, `PostToolUse`,
   `PostToolUseFailure`, `Stop`, `SessionStart`, `PreCompact` (and `PreToolUse`
   only with `-Enforce`).
3. Confirm the paths in `~/.claude/settings.json` exist. The installer writes
   absolute paths; moving `~/.claude` or restoring settings from another machine
   breaks them. Re-run `install.ps1 -Force`.
4. If you set `CLAUDE_CONFIG_DIR` **after** installing, the hooks still point at
   the old tree. Re-run the installer with the variable set.

A quick liveness check: send one prompt, then look at
`~/.claude/state/tuner/<session-id>.json`. Its `updated` field should be recent.
If the file does not exist, `SessionStart` did not run.

## The doctor says "advisory install"

That is not a failure. It means no opus-tuner hooks are registered in the config
dir the doctor inspected, so the six wiring checks are skipped and the skills,
config and scripts are validated on their own. Exit code is 0.

Two things it can mean:

- **You installed with `-NoHooks`**, or copied the skills into a project by hand.
  Nothing automatic runs: no ceilings, no `/compact` refusal, no handoff nudges.
  The skills still work when you invoke them. Run `install.ps1 -Force` to add the
  hooks.
- **The doctor is checking the wrong tree.** It checks the copy it belongs to: run
  from `<root>/skills/opus-tuner/scripts` it inspects `<root>`, not `~/.claude`.
  Pass `-Root "$env:USERPROFILE\.claude"` to check the user-wide install from a
  vendored copy, or `-SkillsOnly` to silence the hooks on purpose.

A *partial* wiring — some events registered, others missing — is not advisory and
still fails. That is a real break: re-run `install.ps1 -Force`.

## Which version is installed?

```powershell
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\doctor.ps1" -Json
```

The `version` field is what you want. Or read the file it comes from:
`~/.claude/skills/opus-tuner/VERSION`. `install.ps1` and `uninstall.ps1` print the
same number in their banner. Bug reports and security advisories need it, and
`git log` is not available to someone who installed from a release archive.

## A hook is slow

Expect ~450 ms per blocking hook. If it is much slower:

- **Windows:** check whether `pwsh.exe` is on PATH. Claude Code prefers it for
  `shell: "powershell"` hooks, and on some machines it starts ~100 ms slower than
  Windows PowerShell 5.1. See the latency section of the
  [technical reference](../skills/opus-tuner/README.md#latency).
- **macOS / Linux:** `pwsh` startup is the floor, and there is no 5.1 to fall
  back to. If hooks take seconds, check whether `pwsh` is being started through a
  wrapper (`snap` and some `brew` installs add one) and measure
  `pwsh -NoProfile -Command 1` directly.
- Antivirus real-time scanning of `powershell.exe` adds a fixed cost per
  invocation. Excluding the script directory is usually enough.
- Run `selftest.ps1`; it prints per-hook timings and fails above the budget.

## `pwsh` is not found (macOS / Linux)

This is the most common POSIX failure. Hooks are written as
`pwsh -NoProfile -File "<path>"`; if `pwsh` is not on `PATH`, Claude Code cannot
start them and nothing fires — no error in the transcript.

```sh
command -v pwsh                     # empty means missing
brew install --cask powershell      # macOS
snap install powershell --classic   # Ubuntu / Debian
```

Then re-run `install.sh`. `doctor.ps1` checks for `pwsh` explicitly on POSIX and
fails the check rather than reporting a healthy install.

## The status line is missing in VS Code

The custom `statusLine` is drawn by the terminal UI. The graphical panel has its
own context indicator and does not render it. Either use the terminal
(`claudeCode.useTerminal`) or ignore it — the hooks do not depend on the status
line.

## `ctx.ps1` prints "ctx unknown"

It could not find a usage block in the transcript tail. Common causes:

- a brand-new session with no assistant message yet;
- `CLAUDE_CONFIG_DIR` points somewhere without a `projects` folder;
- the transcript is being written by a different user or is locked.

Pass `-Transcript <path>` to point at a specific file.

## The hard wrap fired and I did not want it

It fires once per ceiling crossing. If a task genuinely needs more room:

- raise `deepTokens`, or
- start the session in the deep tier by escalating it early (plan mode or a deep
  prompt does this), or
- set `"hardWrap": false` to keep the banner without the block.

If it appears to fire repeatedly, check that the state directory is writable.
Without a persisted `nudged.hardWrap`, each stop looks like the first one.

## I still hit the weekly limit

This bundle reduces waste; it does not raise your plan's limits. If you are at
the limit, the useful questions are:

- What is `PeakCtxK` on your largest sessions? Long sessions that never wrap are
  the usual cause.
- How many sessions run past the deep ceiling? `stats.ps1` shows `hard-wrap`
  rows.
- Are you wrapping at task boundaries, or compacting and continuing? A fresh
  context is cheaper than a summary of a large one.

Check `/usage` for the authoritative numbers; `audit.ps1` estimates the same
shape from transcripts.

## `settings.json` is invalid

The installer refuses to write and tells you so. Restore the newest
`settings.json.bak-*` next to it, fix the JSON, and re-run. The installer never
rewrites a file it could not parse.

## The skills do not appear in `/skills`

Each skill must be a folder containing `SKILL.md` with `name` and `description`
frontmatter. After `-Force`, check that there is no stale folder with the same
name; Claude Code loads every `SKILL.md` under `skills/`. This is also why
`install.ps1` puts backups in `~/.claude/state/opus-tuner-backups/` rather than
next to the skill.

## Uninstall left files behind

- `settings.json.bak-*` and the backups under `state/opus-tuner-backups/` are
  deliberate. Delete them when you are satisfied.
- `-Purge` removes `tuner.config.json` and `state/tuner`, including the decision
  log.
- Project handoff briefs live in `<project>/.claude/handoff.md`. They are project
  files, not part of the install, and uninstall does not touch them.

## macOS and Linux

Supported as of 0.3.0, with one prerequisite: **PowerShell 7 (`pwsh`)**. Claude
Code starts command hooks with `sh` there, so the installer writes
`pwsh -NoProfile -File "<path>"` instead of `& "<path>"`.

If hooks do not fire on macOS or Linux, check in this order:

1. `command -v pwsh` — empty means install it (see above).
2. `/hooks` — the entries should say `shell: bash` and start with `pwsh`.
3. `doctor.ps1` — it checks the interpreter, the paths and the state directory.
4. `install.sh` — re-run it; it refuses to install without `pwsh` rather than
   writing hooks that cannot start.

Two differences from Windows are expected, not bugs:

- `-ExecutionPolicy` is never used, because `pwsh` does not accept it.
- `CLAUDE.md` and `settings.json` are written with LF line endings.

The POSIX path is exercised by the Ubuntu and macOS CI jobs, including
`install.sh` under `bash`. See [platforms.md](platforms.md).
