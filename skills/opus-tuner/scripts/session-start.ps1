# SessionStart hook: reset the tier, warn about things the user cannot see, and
# re-seed from the handoff brief on /clear (or on a fresh startup, which is how
# the VS Code panel often begins a new conversation). A fresh session has no
# cache to invalidate, which is why this is the right moment to change model or
# effort - never mid-session.
#
# Everything it reports goes out as one JSON object: two writes to stdout would
# not parse. systemMessage is free (it never enters the model's context), so the
# warnings cost nothing; only the brief is additionalContext.

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
    # A compaction is the same session with a smaller context: the tier and the
    # counters reset, but the once-per-session limits (the manual /compact
    # refusal and the gear-max ration) must not re-arm, or they stop being
    # once per session.
    if (-not [string]::IsNullOrWhiteSpace($sid)) {
        if ($source -eq 'compact') {
            $old = Read-State $sid
            $fresh = New-State
            $fresh['maxUses'] = [int]$old['maxUses']
            $fresh['nudged']['compact'] = [bool]$old['nudged']['compact']
            Write-State $sid $fresh
        } elseif ($source -ne 'resume' -and $source -ne 'fork') {
            Write-State $sid (New-State)
        }
    }

    $msgs = New-Object System.Collections.ArrayList

    # A typo in tuner.config.json is invisible otherwise: Get-TunerConfig fails
    # open by design, so every knob would silently run on its default.
    $issue = Get-TunerConfigIssue
    if ($issue) { [void]$msgs.Add($issue) }
    if ($cfg.ContainsKey('profileInvalid')) {
        [void]$msgs.Add("tuner.config.json names an unknown profile '$($cfg['profileInvalid'])', so the dev profile is active. Known: dev, creative.")
    }

    # Resuming pays before the first new token: the next request re-reads the
    # whole context. Reporting the estimate costs no model tokens.
    if ($source -eq 'resume' -or $source -eq 'fork') {
        $info = Get-ContextInfo -TranscriptPath ([string]$in['transcript_path'])
        $ceiling = Get-Ceiling $cfg 'routine'
        if ($info.found -and $info.ctx -ge $ceiling) {
            # Opus cache-read rate, same table as audit.ps1. An estimate of the
            # first request, not an invoice.
            $cost = [Math]::Round(($info.ctx / 1e6) * 1.50, 2)
            [void]$msgs.Add("resuming at $(Format-Tokens $info.ctx): the next request re-reads it (~`$$cost at Opus cache-read rates). If that work is finished, /wrap then /clear starts at about 500 tokens.")
        }
    }

    # Where the brief gets picked up. /clear is the primary path. In the VS Code
    # panel a new conversation often starts as 'startup' instead, so accept a
    # brief written in the last 24 hours there; an older one is stale and would
    # resurrect work the session has moved past.
    $body = ''
    if (-not [string]::IsNullOrWhiteSpace($cwd)) {
        $brief = Join-Path (Join-Path $cwd '.claude') 'handoff.md'
        if (Test-Path -LiteralPath $brief) {
            $inject = $false
            if ($source -eq 'clear') {
                $inject = $true
            } elseif ($source -eq 'startup') {
                $age = (Get-Date) - (Get-Item -LiteralPath $brief).LastWriteTime
                if ($age.TotalHours -le 24) { $inject = $true }
            }

            if ($inject) {
                $text = Get-Content -LiteralPath $brief -Raw -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $text = $text -replace "`r`n", "`n"
                    if ($text.Length -gt 6000) { $text = $text.Substring(0, 6000) + "`n...[truncated]" }
                    $body = "Resuming from a handoff brief. It is the working state; continue from its Next step and do not re-explore what it already records.`n`n$text"

                    # Consume it so a later /clear in an unrelated session does
                    # not resurrect it.
                    try { Move-Item -LiteralPath $brief -Destination (Join-Path (Join-Path $cwd '.claude') 'handoff.consumed.md') -Force } catch { }
                }
            }
        }
    }

    # The profile note is the one standing instruction a profile adds. A resumed
    # or forked session already carries it, and compaction may have summarised
    # it away, so it goes in on every source except those two.
    $context = New-Object System.Collections.ArrayList
    $note = [string]$cfg['profileNote']
    if ($note -and $source -ne 'resume' -and $source -ne 'fork') { [void]$context.Add($note) }
    if ($body) { [void]$context.Add($body) }

    $out = @{}
    if ($msgs.Count -gt 0) { $out['systemMessage'] = ($msgs -join ' ') }
    if ($context.Count -gt 0) {
        $out['hookSpecificOutput'] = @{ hookEventName = 'SessionStart'; additionalContext = ($context -join "`n`n") }
    }
    if ($out.Count -gt 0) { Write-HookJson $out }
} catch { }
exit 0
