# Troubleshooting

## Hooks do not fire

0. **Run the doctor.** It checks the whole wiring in one command:

   ```powershell
   powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\doctor.ps1"
   ```

   Exit code 0 means healthy. It names the specific break: a hook pointing at a
   missing script, a config that does not parse, a skill folder without a matching
   `name:`, or an unwritable state directory.

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

## A hook is slow

Expect ~450 ms per blocking hook. If it is much slower:

- Check whether `pwsh.exe` is on PATH. Claude Code prefers it for
  `shell: "powershell"` hooks, and on some machines it starts ~100 ms slower than
  Windows PowerShell 5.1. See the latency section of the
  [technical reference](../skills/opus-tuner/README.md#latency).
- Antivirus real-time scanning of `powershell.exe` adds a fixed cost per
  invocation. Excluding the script directory is usually enough.
- Run `selftest.ps1`; it prints per-hook timings and fails above the budget.

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

Untested. The scripts are PowerShell and pass both suites under `pwsh` 7 on
Windows in CI, but the hook entries use `shell: "powershell"` and the installer
writes Windows paths. If you want to try, install `pwsh`, change the hook shell
to `pwsh`, and expect path and encoding fixes. PRs are welcome, but the supported
runtime is Windows PowerShell 5.1.
