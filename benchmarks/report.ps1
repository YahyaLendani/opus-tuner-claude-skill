# Turns a results directory into report.md and summary.json. Failed runs are listed
# beside the successes. The report compares ranges and draws no conclusion for you.
#
#   powershell -NoProfile -File benchmarks/report.ps1 -Results benchmarks/results/<stamp>
#   powershell -NoProfile -File benchmarks/report.ps1     # the newest results, if any

param([string]$Results = '')

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$minRepeats = 5

function Get-Spread {
    param($Values)
    $v = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $mid = [int][Math]::Floor($v.Count / 2)
    $median = if ($v.Count % 2 -eq 1) { $v[$mid] } else { ($v[$mid - 1] + $v[$mid]) / 2.0 }
    return @{ median = $median; min = $v[0]; max = $v[$v.Count - 1]; n = $v.Count }
}

function Format-Spread {
    param($Spread, [string]$Format = '{0:N0}')
    if ($null -eq $Spread) { return 'n/a' }
    return ($Format -f $Spread.median) + ' (' + ($Format -f $Spread.min) + '-' + ($Format -f $Spread.max) + ')'
}

# Against the default arm. Only says whether the observed ranges are apart.
function Compare-Range {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return 'n/a' }
    if ($A.max -lt $B.min) { return 'below' }
    if ($A.min -gt $B.max) { return 'above' }
    return 'overlaps'
}

$pendingNote = 'PENDING: no live evaluation has been recorded. Nothing here shows that any arm saves tokens, money or time.'
if (-not $Results) {
    $root = Join-Path $PSScriptRoot 'results'
    if (Test-Path -LiteralPath $root) {
        $newest = Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($newest) { $Results = $newest.FullName }
    }
}
if (-not $Results -or -not (Test-Path -LiteralPath (Join-Path $Results 'manifest.json'))) {
    $pendingNote
    'no results directory found. See benchmarks/README.md to produce one.'
    exit 0
}

$manifest = [System.IO.File]::ReadAllText((Join-Path $Results 'manifest.json')) | ConvertFrom-Json
$runsFile = Join-Path $Results 'runs.jsonl'
$runs = @()
if (Test-Path -LiteralPath $runsFile) {
    $runs = @([System.IO.File]::ReadAllLines($runsFile) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
$isLive = ($manifest.live -eq $true)

$md = New-Object System.Collections.ArrayList
function Add-Line { param([string]$Text = '') [void]$md.Add($Text) }

Add-Line '# Benchmark report'
Add-Line ''
if ($isLive) {
    Add-Line "**Live run** of $($runs.Count) planned run(s). Costs are API-equivalent estimates at list prices, from pricing table $($manifest.pricingVersion)."
} else {
    Add-Line "**STUB DATA.** These runs used a stand-in for Claude Code, to test the harness. They say nothing about any arm."
    Add-Line ''
    Add-Line "**$pendingNote**"
}
Add-Line ''
Add-Line "Claude Code $($manifest.claudeVersion), model ``$($manifest.model)``, effort ``$($manifest.effort)``, opus-tuner $($manifest.tunerVersion), commit ``$($manifest.repoCommit)``, $($manifest.platform), PowerShell $($manifest.powershell), seed $($manifest.seed)."
Add-Line ''

$summary = New-Object System.Collections.ArrayList
$cells = @{}
foreach ($taskName in @($manifest.tasks)) {
    Add-Line "## $taskName"
    Add-Line ''
    Add-Line '| Arm | Runs | Correct | Not completed | Tokens, median (range) | Tokens vs default | Cost USD | Minutes | Handoff tokens | Rebuild tokens | Facts lost | Repeated lookups | Interruptions |'
    Add-Line '|---|---|---|---|---|---|---|---|---|---|---|---|---|'
    $baselineTokens = $null
    foreach ($armName in @($manifest.arms)) {
        $group = @($runs | Where-Object { $_.task -eq $taskName -and $_.arm -eq $armName })
        $ran = @($group | Where-Object { $_.status -ne 'not-run' -and $_.status -ne 'harness-error' })
        $tokens = Get-Spread @($ran | Where-Object { $_.tokens } | ForEach-Object { [double]$_.tokens.input + [double]$_.tokens.cacheRead + [double]$_.tokens.cacheWrite + [double]$_.tokens.output })
        if ($armName -eq 'default') { $baselineTokens = $tokens }
        $cost = Get-Spread @($ran | ForEach-Object { $_.costUSD })
        $minutes = Get-Spread @($ran | ForEach-Object { [double]$_.elapsedMs / 60000.0 })
        $handoff = Get-Spread @($ran | ForEach-Object { $_.handoffOverhead.tokens })
        $rebuild = Get-Spread @($ran | ForEach-Object { $_.rebuild.tokens })
        # A run that stopped before the recall step lost nothing that can be counted.
        $lost = Get-Spread @($ran | Where-Object { [int]$_.facts.total -gt 0 } | ForEach-Object { @($_.facts.lost | Where-Object { $_ }).Count })
        $repeated = Get-Spread @($ran | ForEach-Object { $_.repeatedLookups })
        $interrupted = Get-Spread @($ran | ForEach-Object { [double]$_.interruptions.continuations + [double]$_.interruptions.stopPrompts + [double]$_.interruptions.blockedCompactions + [double]$_.interruptions.permissionDenials })
        $correct = @($group | Where-Object { $_.passed -eq $true }).Count
        $incomplete = @($group | Where-Object { $_.status -ne 'completed' }).Count
        $versus = if ($armName -eq 'default') { '-' } else { Compare-Range $tokens $baselineTokens }
        Add-Line ("| {0} | {1} | {2}/{3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} |" -f $armName, $group.Count, $correct, $group.Count, $incomplete, (Format-Spread $tokens), $versus, (Format-Spread $cost '{0:N4}'), (Format-Spread $minutes '{0:N1}'), (Format-Spread $handoff), (Format-Spread $rebuild), (Format-Spread $lost '{0:N1}'), (Format-Spread $repeated '{0:N1}'), (Format-Spread $interrupted '{0:N1}'))
        [void]$summary.Add([ordered]@{
            task = $taskName; arm = $armName; runs = $group.Count; correct = $correct; notCompleted = $incomplete
            tokens = $tokens; tokensVsDefault = $versus; costUSD = $cost; minutes = $minutes; handoffTokens = $handoff; rebuildTokens = $rebuild
            factsLost = $lost; repeatedLookups = $repeated; interruptions = $interrupted
        })
        $cells["$taskName/$armName"] = $group.Count
    }
    Add-Line ''
}

Add-Line '## Failures and wrong results'
Add-Line ''
$problems = @($runs | Where-Object { $_.status -ne 'completed' -or $_.passed -ne $true -or @($_.facts.lost | Where-Object { $_ }).Count -gt 0 -or $_.handoff.verified -eq $false -or $_.handoff.pickedUp -eq $false })
if ($problems.Count -eq 0) {
    Add-Line 'None.'
} else {
    foreach ($p in $problems) {
        $bits = New-Object System.Collections.ArrayList
        [void]$bits.Add("status $($p.status)")
        if ($p.failedStep) { [void]$bits.Add("stopped at $($p.failedStep)") }
        if (@($p.failedChecks).Count -gt 0) { [void]$bits.Add("failed checks: $(@($p.failedChecks) -join '; ')") }
        $gone = @($p.facts.lost | Where-Object { $_ })
        if ($gone.Count -gt 0) { [void]$bits.Add("facts lost: $($gone -join ', ')") }
        if ($p.handoff.verified -eq $false) { [void]$bits.Add('handoff not verified') }
        if ($p.handoff.pickedUp -eq $false) { [void]$bits.Add('handoff not picked up') }
        Add-Line "- $($p.task) / $($p.arm) / repeat $($p.repeat): $($bits -join ', ')"
    }
}
Add-Line ''

Add-Line '## Reading this'
Add-Line ''
Add-Line '- **Tokens vs default** only says whether the observed ranges are apart. `overlaps` means these runs cannot tell the arms apart.'
$thin = @($cells.Values | Where-Object { $_ -lt $minRepeats }).Count
if ($thin -gt 0) { Add-Line "- **Too few runs to compare.** $thin arm and task combination(s) have fewer than $minRepeats runs, so their ranges are not a sound basis for a decision." }
Add-Line '- **Handoff tokens** is the cost of preparing a handoff. **Rebuild tokens** is the first step afterwards, which restates the work from what was carried over. Both are already in the totals.'
Add-Line '- **Facts lost** counts what the recall step could not state. **Repeated lookups** counts reads and searches, after the continuation, that had been made before it. It is a proxy for repeated work: some repeats are sensible.'
Add-Line '- **Interruptions** are steps a user would have to take or answer: handoff continuations, Stop prompts, blocked compactions and denied permissions.'
Add-Line '- These are synthetic tasks on one setup. They do not show what a subscription would be charged, or what happens on your own work.'
Add-Line ''
Add-Line '## Effort routing and compaction blocking'
Add-Line ''
$armsRun = @($manifest.arms)
if ($isLive -and $armsRun -contains 'tuner' -and $armsRun -contains 'tuner-no-routing') {
    Add-Line 'To judge automatic effort routing, compare `tuner` with `tuner-no-routing` above.'
} else {
    Add-Line 'Automatic effort routing: **pending**. It needs a live run with the `tuner` and `tuner-no-routing` arms.'
}
if ($isLive -and $armsRun -contains 'tuner' -and $armsRun -contains 'tuner-guard') {
    Add-Line 'To judge compaction blocking and the Stop prompt, compare `tuner` with `tuner-guard` above, including their interruptions.'
} else {
    Add-Line 'Compaction blocking and the Stop prompt: **pending**. They need a live run with the `tuner` and `tuner-guard` arms.'
}

$reportPath = Join-Path $Results 'report.md'
[System.IO.File]::WriteAllText($reportPath, (($md -join "`n") + "`n"), $utf8)
[System.IO.File]::WriteAllText((Join-Path $Results 'summary.json'), (([ordered]@{ live = $isLive; pending = (-not $isLive); cells = @($summary) }) | ConvertTo-Json -Depth 8), $utf8)
$md -join "`n"
"report written: $reportPath"
exit 0
