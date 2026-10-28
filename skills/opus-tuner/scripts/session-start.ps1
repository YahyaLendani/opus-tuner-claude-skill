# SessionStart hook: reset the tier, and re-seed from the handoff brief on
# /clear (or on a fresh startup, which is how the VS Code panel often begins a
# new conversation). A fresh session has no cache to invalidate, which is why
# this is the right moment to change model or effort - never mid-session.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    if ($cfg['mode'] -eq 'off') { exit 0 }

    $in = Get-HookInput
    $sid = [string]$in['session_id']
    $cwd = [string]$in['cwd']
    $source = [string]$in['source']

    # A resume keeps the tier it had: dropping a 300k deep session back to the
    # routine ceiling would instantly ask it to wrap. Everything else is a slate.
    if (-not [string]::IsNullOrWhiteSpace($sid)) {
        if ($source -ne 'resume' -and $source -ne 'fork') {
            Write-State $sid (New-State)
        }
    }

    # Where the brief gets picked up. /clear is the primary path. In the VS Code
    # panel a new conversation often starts as 'startup' instead, so accept a
    # brief written in the last 24 hours there; an older one is stale and would
    # resurrect work the session has moved past.
    $brief = Join-Path $cwd '.claude\handoff.md'
    if (-not (Test-Path -LiteralPath $brief)) { exit 0 }

    $inject = $false
    if ($source -eq 'clear') {
        $inject = $true
    } elseif ($source -eq 'startup') {
        $age = (Get-Date) - (Get-Item -LiteralPath $brief).LastWriteTime
        if ($age.TotalHours -le 24) { $inject = $true }
    }
    if (-not $inject) { exit 0 }

    $text = Get-Content -LiteralPath $brief -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }
    $text = $text -replace "`r`n", "`n"
    if ($text.Length -gt 6000) { $text = $text.Substring(0, 6000) + "`n...[truncated]" }

    $body = "Resuming from a handoff brief. It is the working state; continue from its Next step and do not re-explore what it already records.`n`n$text"

    # Consume it so a later /clear in an unrelated session does not resurrect it.
    try { Move-Item -LiteralPath $brief -Destination (Join-Path $cwd '.claude\handoff.consumed.md') -Force } catch { }

    Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $body } }
} catch { }
exit 0
