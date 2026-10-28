#!/bin/sh
# opus-tuner installer for macOS and Linux.
#
# Claude Code runs the hooks with PowerShell, so pwsh 7 is required:
#   macOS:  brew install --cask powershell
#   Ubuntu: snap install powershell --classic
#   other:  https://aka.ms/powershell
#
# Usage, from a clone:
#   ./install.sh
#   ./install.sh -Force
#   ./install.sh -NoHooks
#
# Every switch of install.ps1 is passed through unchanged.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if ! command -v pwsh >/dev/null 2>&1; then
    cat >&2 <<'EOF'
opus-tuner needs PowerShell 7 (pwsh) on macOS and Linux, because Claude Code
runs the hooks with it.

  macOS:  brew install --cask powershell
  Ubuntu: snap install powershell --classic
  other:  https://aka.ms/powershell

Then run ./install.sh again.
EOF
    exit 1
fi

exec pwsh -NoProfile -File "$here/install.ps1" "$@"
