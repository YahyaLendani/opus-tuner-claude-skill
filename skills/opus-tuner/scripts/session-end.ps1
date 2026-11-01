# SessionEnd hook: tell the next SessionStart which handoff is safe to pick up.
#
# A new session cannot see which session it replaces, and several can share a
# project, so the session that is ending leaves a marker next to its own verified
# handoff: <sid>.claim when it ran /clear, <sid>.ended in every case. Claude Code
# discards this hook's output and it cannot delay or block anything.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    # The markers only let the next session load a handoff, which monitor never does.
    if (@('off', 'monitor') -contains $cfg['mode']) { exit 0 }

    $in = Get-HookInput
    $sid = [string]$in['session_id']
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }

    $h = Read-Handoff (Get-HandoffPath $sid)
    if (-not $h -or $h['status'] -ne 'ready' -or $h['session_id'] -cne $sid) { exit 0 }

    $cwd = [string]$in['cwd']
    Set-HandoffMarker -SessionId $sid -Kind 'ended' -Cwd $cwd
    if ([string]$in['reason'] -eq 'clear') { Set-HandoffMarker -SessionId $sid -Kind 'claim' -Cwd $cwd }
} catch { }
exit 0
