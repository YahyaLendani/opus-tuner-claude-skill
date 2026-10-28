# PreCompact hook: compaction is the expensive thing this bundle exists to
# avoid, so it should at least be visible.
#
# Two jobs:
#   1. Record every compaction in the decision log. PreCompact discards
#      systemMessage, so a log row is the only way "how often did it happen"
#      can be answered later (stats.ps1 counts them).
#   2. Refuse the first *manual* /compact per session, once. Compaction pays a
#      full context read, and its summary is then re-read on every later
#      request; a handoff brief plus /clear starts at ~500 tokens instead.
#
# Automatic compaction is never blocked. If it was triggered to recover from a
# context-limit error the API already returned, blocking it surfaces that error
# and fails the request - a worse outcome than the compaction itself.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    if ($cfg['mode'] -eq 'off') { exit 0 }

    $in = Get-HookInput
    $sid = [string]$in['session_id']
    $trigger = [string]$in['trigger']
    if ($trigger -ne 'manual') { $trigger = 'auto' }

    $state = Read-State $sid
    $tier = [string]$state['tier']
    if ($tier -ne 'deep') { $tier = 'routine' }
    $gear = [string]$state['gear']
    $ceiling = Get-Ceiling $cfg $tier
    $ctx = [int64](Get-ContextInfo -TranscriptPath ([string]$in['transcript_path'])).ctx

    Write-Decision $cfg $sid $ctx $tier $gear "compact-$trigger"

    if ($trigger -ne 'manual') { exit 0 }

    $blockManual = $true
    if ($cfg.ContainsKey('blockManualCompact')) { $blockManual = [bool]$cfg['blockManualCompact'] }
    if (-not $blockManual) { exit 0 }

    # One shot per session, like the hard wrap. A second /compact means the user
    # heard the reason and still wants it; refusing again would be a trap.
    if ([bool]$state['nudged']['compact']) { exit 0 }

    $state['nudged']['compact'] = $true
    Write-State $sid $state
    Write-Decision $cfg $sid $ctx $tier $gear 'compact-blocked'

    $where = if ($ctx -gt 0) {
        if ($ctx -lt $ceiling) {
            "You are at $(Format-Tokens $ctx), below the $tier ceiling ($(Format-Tokens $ceiling)), so compacting here buys nothing."
        } else {
            "You are at $(Format-Tokens $ctx), at the $tier ceiling."
        }
    } else { '' }

    Write-HookJson @{
        decision = 'block'
        reason   = ("Compaction re-reads the entire context to write a summary, and that summary is then re-read on every later request. " +
                    "$where Run /wrap to write .claude/handoff.md, then tell the user to /clear - a fresh session starts at about 500 tokens. " +
                    "This blocks once per session: run /compact again if you still want it.")
    }
} catch { }
exit 0
