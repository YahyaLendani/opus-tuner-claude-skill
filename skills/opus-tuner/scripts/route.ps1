# UserPromptSubmit hook: classify the prompt, escalate the tier, pick an effort gear.
# Escalate-only. Never resets the tier mid-session: UserPromptSubmit also fires on
# subagent reports and scheduled tasks, which must not knock a session back down.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    $cfg = Get-TunerConfig
    if ($cfg['mode'] -eq 'off') { exit 0 }

    $in    = Get-HookInput
    $sid   = [string]$in['session_id']
    $cwd   = [string]$in['cwd']
    $prompt = [string]$in['prompt']
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

    $state = Read-State $sid
    $ctxInfo = Get-ContextInfo -TranscriptPath ([string]$in['transcript_path'])
    $ctx = [int64]$ctxInfo.ctx

    $tier = [string]$state['tier']
    if ($tier -ne 'deep') { $tier = 'routine' }
    $ceiling = Get-Ceiling $cfg $tier
    $grace = [int64]$cfg['graceTokens']

    # Did the previous low-gear turn pay? A failure during it means low effort
    # likely caused rework, which costs more than the gear saved. One row per
    # low turn lets session start switch the downshift off when it keeps
    # misfiring (see Update-AutoTune).
    $stateDirty = $false
    if ([string]$state['gear'] -eq 'low') {
        $outcome = if ([bool]$state['lowFailed']) { 'low-failed' } else { 'low-ok' }
        Write-Decision $cfg $sid $ctx $tier 'low' $outcome
        $state['gear'] = 'high'
        $state['lowFailed'] = $false
        $stateDirty = $true
    }

    # Grace: a task that is nearly finished should not be cut off at the line.
    # Between the routine ceiling and ceiling+grace the tier steps up to deep
    # instead of asking for a wrap. This has to happen before the ceiling test,
    # or the ceiling test fires first and grace is unreachable.
    $graceEscalated = $false
    if ($tier -eq 'routine' -and $ctx -ge $ceiling -and $ctx -lt ($ceiling + $grace)) {
        $tier = 'deep'
        $ceiling = Get-Ceiling $cfg 'deep'
        $state['tier'] = 'deep'
        $graceEscalated = $true
    }

    $planMode = ([string]$in['permission_mode']) -eq 'plan'
    $fails = [int]$state['fails']

    $fileCount = 0
    if ($state['files'] -is [System.Collections.IEnumerable] -and -not ($state['files'] -is [string])) {
        $fileCount = @($state['files']).Count
    }

    # Strong words ("race condition", "refactor") escalate on their own. Weak
    # ones ("why is", "performance") also turn up in everyday questions, so they
    # count only alongside a second signal that the work is genuinely hard: a
    # failure already, several files touched, plan mode, or a long, detailed
    # prompt. An empty pattern list means "none", never "match everything".
    $strongHit = ([string]$cfg['deepPatterns']) -and ($prompt -match $cfg['deepPatterns'])
    $weakHit = ([string]$cfg['weakDeepPatterns']) -and ($prompt -match $cfg['weakDeepPatterns'])
    $secondSignal = ($fails -ge 1) -or ($fileCount -ge 3) -or $planMode -or ($prompt.Length -ge 400)
    $deepHit = $strongHit -or ($weakHit -and $secondSignal)
    $mechHit = ($prompt -match $cfg['mechanicalPatterns']) -and (-not ($strongHit -or $weakHit)) -and ($prompt.Length -lt 260)
    $bulkHit = $prompt -match $cfg['bulkPatterns']

    $notes = New-Object System.Collections.ArrayList
    $gear = 'high'

    # 1. Hard ceiling wins over everything: tell the model to wrap, not to work.
    #    Said once per crossing. Repeating it on every prompt would add the same
    #    ~70 tokens to a context that is already at its most expensive; after
    #    the first time, the Stop hook's block and the status line carry it.
    #    Own flag, not nudged.ceiling: that one belongs to stop.ps1, and setting
    #    it here would suppress the user-facing /wrap banner at the next stop.
    if ($ctx -ge $ceiling) {
        if (-not [bool]$state['nudged']['routeCeiling']) {
            $state['nudged']['routeCeiling'] = $true
            Write-State $sid $state
            Write-Decision $cfg $sid $ctx $tier $gear 'ceiling'
            [void]$notes.Add("[tuner] ctx $(Format-Tokens $ctx) is at the $tier ceiling ($(Format-Tokens $ceiling)). Stop starting new work. Run /wrap, then tell the user to /clear. The Stop hook blocks one stop at this ceiling, so write the brief now.")
            Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = ($notes -join ' ') } }
        } elseif ($stateDirty) {
            Write-State $sid $state
        }
        exit 0
    }

    # 2. Escalate the tier on any strong signal. Wrong-routine degrades gracefully
    #    into deep; wrong-deep would carry 250k for the rest of the session.
    $escalate = $false
    $reason = ''
    if ($tier -eq 'routine') {
        if ($deepHit)              { $escalate = $true; $reason = 'prompt' }
        elseif ($fails -ge 2)      { $escalate = $true; $reason = 'repair-loop' }
        elseif ($fileCount -ge 6)  { $escalate = $true; $reason = 'breadth' }
        elseif ($planMode)         { $escalate = $true; $reason = 'plan-mode' }
    }

    # 3. Gear. Default is high and costs nothing: no skill call, no extra request.
    #    Every change of gear buys one extra request that re-reads the context, so a
    #    downshift must clearly pay. Below ~200k the skill call costs about what the
    #    saved thinking is worth, so bulk wording has to justify it there.
    if ($mechHit -and [bool]$cfg['downshift'] -and $ctx -ge [int64]$cfg['minCtxForDownshift']) {
        $mayDown = $true
        if ([bool]$cfg['downshiftRequiresBulk'] -and (-not $bulkHit) -and $ctx -lt 200000) { $mayDown = $false }
        if ($mayDown) { $gear = 'low' }
    }

    if ($deepHit -and $fails -ge 2) {
        if ([int]$state['maxUses'] -lt [int]$cfg['maxTurnsPerSession']) {
            $gear = 'max'
            $state['maxUses'] = [int]$state['maxUses'] + 1
        } else {
            $gear = 'xhigh'
        }
    } elseif ($escalate -and $deepHit) {
        $gear = 'xhigh'
    }

    if ($escalate) {
        $state['tier'] = 'deep'
        [void]$notes.Add("[tuner] tier=deep ($reason), ceiling $(Format-Tokens $cfg['deepTokens'])")
    } elseif ($graceEscalated) {
        [void]$notes.Add("[tuner] tier=deep (grace), ceiling $(Format-Tokens $cfg['deepTokens'])")
    }

    if ($gear -ne 'high') {
        $state['gear'] = $gear
        [void]$notes.Add("[tuner] gear=$gear - invoke /gear-${gear} before acting")
    }

    if ($notes.Count -gt 0) {
        Write-State $sid $state
        $action = if ($escalate) { "escalate-$reason" } elseif ($graceEscalated) { 'escalate-grace' } else { "gear-$gear" }
        Write-Decision $cfg $sid $ctx $state['tier'] $gear $action
        Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = ($notes -join '. ') } }
    } elseif ($stateDirty) {
        Write-State $sid $state
    }
} catch { }
exit 0
