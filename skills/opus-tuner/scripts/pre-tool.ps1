# PreToolUse hook (Read): in "enforce" mode, refuse bulk reads once the tier
# ceiling is reached. A burst of full-file reads is what pushes a session past
# the cap between two of the model's decisions.
# Default mode is "advise", where this script exits immediately.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    if ($cfg['mode'] -ne 'enforce') { exit 0 }

    $in = Get-HookInput
    $tool = [string]$in['tool_name']
    if ($tool -ne 'Read') { exit 0 }

    $state = Read-State ([string]$in['session_id'])
    $tier = [string]$state['tier']
    $ceiling = Get-Ceiling $cfg $tier

    $ctx = [int64](Get-ContextInfo -TranscriptPath ([string]$in['transcript_path'])).ctx
    if ($ctx -le 0 -or $ctx -lt $ceiling) { exit 0 }

    $ti = $in['tool_input']
    $limit = 0
    if ($ti -is [System.Collections.IDictionary] -and $ti.Contains('limit') -and $ti['limit']) {
        $limit = [int]$ti['limit']
    }

    if ($limit -eq 0 -or $limit -gt 400) {
        Write-HookJson @{
            hookSpecificOutput = @{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'deny'
                permissionDecisionReason = "Context is at $(Format-Tokens $ctx), the $tier ceiling ($(Format-Tokens $ceiling)). Pass offset/limit <= 400, grep first, or wrap: run brief.ps1 then /clear."
            }
        }
    }
} catch { }
exit 0
