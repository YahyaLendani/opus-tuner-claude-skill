# Platforms and clients

opus-tuner is one PowerShell codebase. The scripts are identical everywhere;
only three things change: where the home directory is, how a path is joined, and
which interpreter Claude Code uses to start a hook. The installer resolves all
three at install time and writes the result into `settings.json`.

## What runs where

| Client | Hooks | Gears, `/wrap`, status line | What to install |
|---|---|---|---|
| Claude Code, terminal — Windows | yes | yes | `install.ps1` |
| Claude Code, terminal — macOS / Linux | yes | yes | `install.sh` (needs `pwsh`) |
| Claude Code, VS Code panel — any OS | yes | yes, except the status line | same as terminal |
| Claude Code, Desktop app | yes | yes, except the status line | same as terminal |
| Claude Desktop / claude.ai (plain) | **no** | no | the `claude-skill` skill |
| Claude Code with hooks blocked by policy | **no** | advisory only | `-NoHooks` |

Hooks are a Claude Code feature. They do not exist in claude.ai or in the plain
Desktop chat, which is why the portable [`claude-skill`](../skills/claude-skill/SKILL.md)
exists: it is the same discipline as a document, with no measurement and no
enforcement.

## Windows

Nothing to install. Windows PowerShell 5.1 ships with Windows 10 and 11, and the
installer writes hooks that run through it.

```powershell
git clone https://github.com/YahyaLendani/opus-tuner.git
cd opus-tuner
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

The hook command is `& "<path>"` with `"shell": "powershell"`. `pwsh` 7 works
too, but 5.1 starts faster on most machines and is the measured default. If you
already have `pwsh` on `PATH`, Claude Code may prefer it for
`"shell": "powershell"` hooks; that is a Claude Code decision, not this
installer's.

## macOS and Linux

Claude Code starts command hooks with `sh`, so the scripts need an interpreter.
This bundle uses **PowerShell 7 (`pwsh`)**: it is the only way to keep one
implementation instead of a bash twin that drifts.

```sh
# 1. PowerShell 7
brew install --cask powershell          # macOS
snap install powershell --classic       # Ubuntu / Debian
# Fedora: sudo dnf install powershell
# other:  https://aka.ms/powershell

# 2. install
git clone https://github.com/YahyaLendani/opus-tuner.git
cd opus-tuner
./install.sh
```

`install.sh` is a 30-line wrapper: it checks that `pwsh` is on `PATH`, prints the
install command for your OS if it is not, then runs `install.ps1` with every
switch passed through unchanged (`./install.sh -Force`, `./install.sh -NoHooks`,
`./install.sh -DryRun`). You can skip it and call `pwsh -NoProfile -File
install.ps1` directly.

On POSIX the installer writes `"shell": "bash"` with a `pwsh -NoProfile -File
"<path>"` command. `-ExecutionPolicy` is a Windows-only parameter and is never
emitted there; passing it to `pwsh` on macOS or Linux fails before the script
starts.

## Terminal, VS Code, Desktop

All three run the same Claude Code binary and read the same
`~/.claude/settings.json`, so the hook set is identical. Two differences are
worth knowing:

- **The status line.** It is drawn by the terminal UI. The VS Code graphical
  panel and the Desktop app have their own context indicator and do not render a
  custom `statusLine`. The hooks do not depend on it; nothing breaks, you just
  lose the `[tuner]` badge.
- **Reload semantics.** The terminal reads hooks at process start. The VS Code
  panel needs *Developer: Reload Window* after an install or upgrade. The Desktop
  app needs a restart.

Nothing in the bundle inspects the client, so a config written by one is valid
for the others on the same machine.

## Where files live

`CLAUDE_CONFIG_DIR` overrides the root everywhere. Otherwise:

| Item | Windows | macOS / Linux |
|---|---|---|
| Config root | `%USERPROFILE%\.claude` | `~/.claude` |
| Skills | `…\.claude\skills\<name>` | `~/.claude/skills/<name>` |
| Settings | `…\.claude\settings.json` | `~/.claude/settings.json` |
| State | `…\.claude\state\tuner\` | `~/.claude/state/tuner/` |
| Version | `…\.claude\skills\opus-tuner\VERSION` | `~/.claude/skills/opus-tuner/VERSION` |
| Handoff brief | `<project>\.claude\handoff.md` | `<project>/.claude/handoff.md` |

The handoff brief is the one path that follows the **project**, not the config
root. A brief written on Windows is readable on macOS: it is UTF-8 and the
project-relative location is the same.

## Advisory mode (`-NoHooks`)

For machines where hooks are blocked, or where you want the rules without any
automation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoHooks
```

```sh
./install.sh -NoHooks
```

This installs seven skills (including the hook-free `claude-skill`, but not
`profile`, which needs hooks) and the `CLAUDE.md` block, and does not read or
write `settings.json` at all. Consequences, stated plainly:

- no ceilings are measured, no state is written, no decision log exists;
- `/wrap` still works, because it is a skill that runs `brief.ps1`;
- the gear skills still work when the model chooses them, but nothing routes to
  them;
- `doctor.ps1` reports an advisory install (`skip` on the six wiring checks) and
  exits 0 rather than failing; a partial wiring still fails.

If a previous install left hooks behind, `-NoHooks` warns you and points at
`uninstall.ps1 -KeepSkills`, which removes the hooks while keeping the skills.

## Removing it (macOS and Linux)

There is no `uninstall.sh`. The uninstaller is a PowerShell script like
everything else, so it needs `pwsh` — the same prerequisite as installing:

```sh
pwsh -NoProfile -File uninstall.ps1
pwsh -NoProfile -File uninstall.ps1 -KeepSkills   # drop the hooks, keep the skills
pwsh -NoProfile -File uninstall.ps1 -Purge        # also delete config and state
```

Deleting `~/.claude/skills/opus-tuner` by hand is not enough: the hook entries in
`settings.json` survive and then fire against missing scripts. Run the
uninstaller.

## Plain Claude (Desktop / claude.ai)

Hooks are not available, so the bundle ships a second, self-contained skill:
[`skills/claude-skill/SKILL.md`](../skills/claude-skill/SKILL.md). It carries the
tier ceilings, the token rules, the handoff template and the resume procedure as
prose. Install it the way your client supports skills:

- **Claude Desktop / claude.ai with skills enabled:** upload or add the
  `claude-skill` folder as a skill.
- **No skill support:** paste the body of `SKILL.md` into the project's custom
  instructions.

It is advisory by design. It cannot see the real token count, cannot stop a turn,
and cannot re-seed a session. It says so itself, so the model does not overclaim.

## CI

`.github/workflows/test.yml` runs three jobs:

| Job | Runtime | Blocking |
|---|---|---|
| `windows-powershell-51` | Windows PowerShell 5.1 | yes |
| `windows-pwsh-7` | `pwsh` 7 on Windows | no (timing variance) |
| `posix` | Ubuntu and macOS, `pwsh` 7 | yes |

The POSIX job also executes `install.sh` under `bash` against a temporary
`CLAUDE_CONFIG_DIR`, which is the only place the wrapper's executable bit, its
LF line endings and its switch pass-through are verified. `.gitattributes` pins
`*.sh` to LF for the same reason: a CRLF shebang does not run.

## Known limits

- **`pwsh` is a real dependency on macOS and Linux.** Without it, hooks silently
  fail to start. `doctor.ps1` checks for it explicitly on POSIX.
- **PowerShell startup is ~150 ms per hook.** The same cost exists on Windows;
  see the latency section of the [technical reference](../skills/opus-tuner/README.md#latency).
- **No native Windows-free path.** There is no bash implementation and none is
  planned; see [decisions.md](decisions.md#13-pwsh-7-on-macos-and-linux).
- **Paths are absolute in `settings.json`.** Moving `~/.claude`, or restoring
  settings from another machine or user, breaks them. Re-run the installer.
