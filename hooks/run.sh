#!/usr/bin/env bash
# Runs one opus-tuner hook for the plugin install: hooks.json calls
#   bash "${CLAUDE_PLUGIN_ROOT}/hooks/run.sh" <script name without .ps1>
# and this picks the PowerShell the platform has. stdin and stdout pass straight
# through, so the hook script sees the payload and Claude Code sees its output.
#
# Windows always has Windows PowerShell 5.1. macOS and Linux need pwsh 7; set
# OPUS_TUNER_PWSH to its path when it is not on the PATH Claude Code was given.

root="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}"
script="$root/skills/opus-tuner/scripts/$1.ps1"

# The hook scripts read this to know they came through the plugin.
export OPUS_TUNER_VIA_PLUGIN=1

if [ "$OS" = "Windows_NT" ]; then
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script"
fi

pwsh_bin="${OPUS_TUNER_PWSH:-}"
if [ -z "$pwsh_bin" ]; then
    pwsh_bin="$(command -v pwsh 2>/dev/null)"
fi
if [ -z "$pwsh_bin" ]; then
    # An app started from the Dock or a launcher may not get the shell's PATH.
    for p in /opt/homebrew/bin/pwsh /usr/local/bin/pwsh /usr/bin/pwsh /snap/bin/pwsh "$HOME/.dotnet/tools/pwsh"; do
        if [ -x "$p" ]; then pwsh_bin="$p"; break; fi
    done
fi
if [ -n "$pwsh_bin" ] && [ -x "$pwsh_bin" ]; then
    exec "$pwsh_bin" -NoProfile -File "$script"
fi

# No pwsh: fail open, so a missing interpreter never blocks Claude Code, and say
# so once per session rather than on every prompt.
if [ "$1" = "session-start" ]; then
    printf '%s\n' '{"systemMessage":"opus-tuner is installed but cannot run: it needs PowerShell 7 (pwsh) on macOS and Linux. Install it (brew install --cask powershell, or see https://aka.ms/install-powershell), then restart Claude Code. If pwsh is installed outside PATH, set OPUS_TUNER_PWSH to its full path."}'
fi
exit 0
