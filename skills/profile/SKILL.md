---
name: profile
description: Switch opus-tuner between the dev and creative profiles, or show the active one. Run by the user, never automatically.
argument-hint: "[dev|creative|show]"
disable-model-invocation: true
---

# Profile

Run the switcher with the user's argument exactly as given. No argument swaps
dev and creative; `show` changes nothing.

```
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\opus-tuner\scripts\profile.ps1" $ARGUMENTS

# macOS / Linux
pwsh -NoProfile -File "$HOME/.claude/skills/opus-tuner/scripts/profile.ps1" $ARGUMENTS
```

If `CLAUDE_CONFIG_DIR` is set, substitute it for `~/.claude` in that path.

The script prints the active profile and the exact instruction it adds. From
this point on, follow that instruction for the rest of the session; if it says
the creative instruction no longer applies, drop it.

Then tell the user, in one line, which profile is active.
