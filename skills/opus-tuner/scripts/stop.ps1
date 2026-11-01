# Stop hook: the zero-token banner, and the one hard gate in the bundle.
#
# Three stages, deduped per threshold crossing so it never becomes wallpaper:
#   70% of ceiling       -> quiet warning, finish the current unit
#   ceiling..+grace      -> auto-escalate to deep instead of cutting a task off
#   100% of ceiling      -> block once: write the brief before doing anything else
#
# Grace is tested before the ceiling, because it is a band that straddles the
# routine line; testing the ceiling first would make grace unreachable.
#
# The block is what makes the ceiling real. `decision: "block"` refuses the stop
# and hands the model a reason, so it cannot simply keep working past 150k. It
# fires at most once per crossing: `stop_hook_active` covers the continuation
# Claude Code starts, and nudged.hardWrap covers everything else, so a model that
# ignores the reason can still finish. Never loop a user's session.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    if ($cfg['mode'] -eq 'off') { exit 0 }

    $in = Get-HookInput
    $sid = [string]$in['session_id']

    $ctx = [int64](Get-ContextInfo -TranscriptPath ([string]$in['transcript_path'])).ctx
    if ($ctx -le 0) { exit 0 }

    # Everything that decides from the flags and sets them happens inside one
    # update, so two overlapping stops cannot both see a flag unset.
    $result = @{ msgs = (New-Object System.Collections.ArrayList); rows = (New-Object System.Collections.ArrayList); reason = '' }
    $saved = Update-State $sid {
        param($state)
        $tier = [string]$state['tier']
        if ($tier -ne 'deep') { $tier = 'routine' }
        $ceiling = Get-Ceiling $cfg $tier
        $soft = [int64]([double]$cfg['nudgeAt'] * $ceiling)
        $grace = [int64]$cfg['graceTokens']
        $graceEscalated = $false

        # Grace first, for the same reason as route.ps1: at routine ceiling + a
        # little, the session steps up rather than being stopped mid-task.
        if ($tier -eq 'routine' -and $ctx -ge $ceiling -and $ctx -lt ($ceiling + $grace)) {
            if (-not [bool]$state['nudged']['escalated']) {
                $state['tier'] = 'deep'
                $state['nudged']['escalated'] = $true
                $tier = 'deep'
                $ceiling = Get-Ceiling $cfg 'deep'
                $graceEscalated = $true
                [void]$result['msgs'].Add("ctx $(Format-Tokens $ctx) passed the routine ceiling, auto-escalated to deep ($(Format-Tokens $ceiling)) so the task can finish.")
                [void]$result['rows'].Add(@('deep', 'escalate-grace'))
            }
        }

        if ($ctx -ge $ceiling) {
            $stopHookActive = [bool]$in['stop_hook_active']
            $alreadyBlocked = [bool]$state['nudged']['hardWrap']
            $hardWrap = $true
            if ($cfg.ContainsKey('hardWrap')) { $hardWrap = [bool]$cfg['hardWrap'] }

            if ($hardWrap -and -not $alreadyBlocked -and -not $stopHookActive) {
                # Leave nudged.ceiling alone: the next stop should still show the
                # user-facing banner, because pressing /clear is their step.
                $state['nudged']['hardWrap'] = $true
                [void]$result['rows'].Add(@($tier, 'hard-wrap'))
                $result['reason'] = ("Context is at the {0} ceiling ({1} of {2}). Do not start new work. " +
                    "Invoke /wrap now, fill its sections from the transcript, and tell the user to run /clear. " +
                    "Do not /compact. This is the only interruption; your next stop will be allowed.") -f $tier, (Format-Tokens $ctx), (Format-Tokens $ceiling)
                return
            }

            if (-not [bool]$state['nudged']['ceiling']) {
                [void]$result['msgs'].Add("ctx $(Format-Tokens $ctx) reached the $tier ceiling ($(Format-Tokens $ceiling)). Run /wrap to write the brief, then /clear.")
                $state['nudged']['ceiling'] = $true
            }
        } elseif (-not $graceEscalated -and $ctx -ge $soft) {
            if (-not [bool]$state['nudged']['soft']) {
                [void]$result['msgs'].Add("ctx $(Format-Tokens $ctx)/$(Format-Tokens $ceiling) ($tier). Finish this unit of work, then /wrap.")
                $state['nudged']['soft'] = $true
            }
        }
    }

    # Not saved means the flag is not on disk: interrupting now could repeat.
    if (-not $saved) { exit 0 }

    foreach ($row in $result['rows']) { Write-Decision $cfg $sid $ctx $row[0] 'high' $row[1] }
    if ($result['reason']) {
        Write-HookJson @{ decision = 'block'; reason = $result['reason'] }
    } elseif ($result['msgs'].Count -gt 0) {
        Write-HookJson @{ systemMessage = ($result['msgs'] -join ' ') }
    }
} catch { }
exit 0
