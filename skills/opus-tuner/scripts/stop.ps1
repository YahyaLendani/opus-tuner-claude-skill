# Stop hook: the zero-token banner, and an optional one-time handoff prompt.
#
# Three stages, deduped per threshold crossing so it never becomes wallpaper:
#   70% of ceiling       -> quiet note
#   ceiling..+grace      -> auto-escalate to deep instead of cutting a task off
#   100% of ceiling      -> banner, or in guard mode with hardWrap, one prompt
#
# Grace is tested before the ceiling, because it is a band that straddles the
# routine line; testing the ceiling first would make grace unreachable.
#
# The prompt is not a limit. `decision: "block"` only refuses one stop and hands
# the model a reason: nothing stops work between stops, or after this one. It
# fires at most once per crossing: `stop_hook_active` covers the continuation
# Claude Code starts, and nudged.hardWrap covers everything else, so a model that
# ignores the reason can still finish. Never loop a user's session.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    if ($cfg['mode'] -eq 'off') { exit 0 }
    $monitor = ([string]$cfg['mode'] -eq 'monitor')

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
        if (-not $monitor -and $tier -eq 'routine' -and $ctx -ge $ceiling -and $ctx -lt ($ceiling + $grace)) {
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

            if ((Test-Interruption $cfg 'hardWrap') -and -not $alreadyBlocked -and -not $stopHookActive) {
                # Leave nudged.ceiling alone: the next stop should still show the
                # user-facing banner, because pressing /clear is their step.
                $state['nudged']['hardWrap'] = $true
                [void]$result['rows'].Add(@($tier, 'hard-wrap'))
                $result['reason'] = ("One-time handoff prompt: context is at the {0} ceiling ({1} of {2}). This is not a limit, and your next stop will be allowed. " +
                    "If work remains, invoke /wrap, fill and verify the handoff, then ask the user to run /clear. " +
                    "If the work is done, say so.") -f $tier, (Format-Tokens $ctx), (Format-Tokens $ceiling)
                return
            }

            if (-not [bool]$state['nudged']['ceiling']) {
                $advice = if ($monitor) { '' } else { ' To continue in a fresh session, run /wrap, then /clear.' }
                [void]$result['msgs'].Add("ctx $(Format-Tokens $ctx) reached the $tier ceiling ($(Format-Tokens $ceiling)).$advice")
                $state['nudged']['ceiling'] = $true
            }
        } elseif (-not $graceEscalated -and $ctx -ge $soft) {
            if (-not [bool]$state['nudged']['soft']) {
                $advice = if ($monitor) { '' } else { ' To continue in a fresh session later, run /wrap when this unit of work is done.' }
                [void]$result['msgs'].Add("ctx $(Format-Tokens $ctx)/$(Format-Tokens $ceiling) ($tier).$advice")
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
