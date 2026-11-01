# Tests the benchmark harness offline, against the stub. It proves the harness and
# the graders work, and says nothing about the arms: no model is ever called.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/benchmark-test.ps1
#   pwsh -NoProfile -File tests/benchmark-test.ps1 -Interpreter pwsh

param([string]$Interpreter = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Interpreter = Get-TestInterpreter $Interpreter
$null = New-TestSandbox 'benchmark'

$bench = Join-Path $script:RepoRoot 'benchmarks'
$exe = @(Get-ExePrefix)
function Invoke-Ps {
    param([string]$File, [string[]]$Arguments = @())
    $ErrorActionPreference = 'Continue'
    $text = & $script:Interpreter @exe -File $File @Arguments 2>&1 | Out-String
    return @{ text = $text; code = $LASTEXITCODE }
}
function Get-Runs {
    param([string]$Dir)
    $file = Join-Path $Dir 'runs.jsonl'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    return @([System.IO.File]::ReadAllLines($file) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Test-Near { param($A, $B) return ($null -ne $A -and [Math]::Abs([double]$A - [double]$B) -lt 1e-9) }

Write-Host "benchmark tests  (interpreter: $($script:Interpreter))" -ForegroundColor Cyan

Write-Section 'the graders tell right from wrong'
foreach ($taskDir in @(Get-ChildItem -LiteralPath (Join-Path $bench 'tasks') -Directory)) {
    $name = $taskDir.Name
    $task = [System.IO.File]::ReadAllText((Join-Path $taskDir.FullName 'task.json')) | ConvertFrom-Json
    $workSteps = @($task.steps | Where-Object { $_.kind -eq 'work' } | ForEach-Object { [string]$_.id })
    Check "${name}: has a continuation and a recall step" (@($task.steps | Where-Object { $_.kind -eq 'continuation' }).Count -eq 1 -and @($task.steps | Where-Object { $_.kind -eq 'recall' }).Count -eq 1)
    foreach ($f in @(@($task.steps | Where-Object { $_.kind -eq 'recall' })[0].facts)) {
        Check "${name}: fact $($f.id) accepts its sample" ([string]$f.sample -match [string]$f.pattern)
    }

    $untouched = Join-Path $script:Sandbox "$name-untouched"
    $null = Invoke-Ps (Join-Path $taskDir.FullName 'setup.ps1') @('-Path', $untouched)
    $g = (Invoke-Ps (Join-Path $taskDir.FullName 'check.ps1') @('-Path', $untouched)).text | ConvertFrom-Json
    Check "${name}: fails an untouched workspace" ($g.passed -eq $false)

    $good = Join-Path $script:Sandbox "$name-good"
    $null = Invoke-Ps (Join-Path $taskDir.FullName 'setup.ps1') @('-Path', $good)
    foreach ($s in $workSteps) { $null = Invoke-Ps (Join-Path $taskDir.FullName 'solve.ps1') @('-Path', $good, '-Step', $s) }
    $raw = (Invoke-Ps (Join-Path $taskDir.FullName 'check.ps1') @('-Path', $good)).text
    $g = $raw | ConvertFrom-Json
    Check "${name}: passes the reference solution" ($g.passed -eq $true) $raw

    $half = Join-Path $script:Sandbox "$name-half"
    $null = Invoke-Ps (Join-Path $taskDir.FullName 'setup.ps1') @('-Path', $half)
    $null = Invoke-Ps (Join-Path $taskDir.FullName 'solve.ps1') @('-Path', $half, '-Step', $workSteps[0])
    $g = (Invoke-Ps (Join-Path $taskDir.FullName 'check.ps1') @('-Path', $half)).text | ConvertFrom-Json
    Check "${name}: fails work stopped after the first phase" ($g.passed -eq $false)

    $bad = Join-Path $script:Sandbox "$name-bad"
    $null = Invoke-Ps (Join-Path $taskDir.FullName 'setup.ps1') @('-Path', $bad)
    foreach ($s in $workSteps) { $null = Invoke-Ps (Join-Path $taskDir.FullName 'solve.ps1') @('-Path', $bad, '-Step', $s, '-Violate') }
    $g = (Invoke-Ps (Join-Path $taskDir.FullName 'check.ps1') @('-Path', $bad)).text | ConvertFrom-Json
    $failed = @(@($g.checks) | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) -join '; '
    Check "${name}: fails working code that broke an earlier rule" ($g.passed -eq $false -and $failed -match 'rule|decision') $failed
}

Write-Section 'nothing is spent by accident'
$log = Join-Path $script:Sandbox 'stub-calls.jsonl'
$env:BENCH_STUB_LOG = $log
$stub = Join-Path (Join-Path $bench 'stub') 'claude-stub.ps1'
$run = Join-Path $bench 'run.ps1'
$r = Invoke-Ps $run @('-ClaudePath', $stub)
Check 'with no flags it only prints the plan' ($r.code -eq 0 -and $r.text -match 'no model was called') $r.text
Check 'and calls nothing' (-not (Test-Path -LiteralPath $log))

$env:ANTHROPIC_API_KEY = 'sk-ant-test-SYNTHETIC-benchmark-key-0123456789'
$liveBase = @('-AllowLive', '-ClaudePath', $stub, '-Arms', 'default', '-Tasks', 'ledger-rules', '-Repeats', '1')
$cases = @(
    @{ name = 'an alias instead of a model id'; extra = @('-Model', 'sonnet', '-ExpectVersion', '0.0.0-stub', '-MaxRunUsd', '1', '-MaxTotalUsd', '1'); want = 'full model id' }
    @{ name = 'no pinned version'; extra = @('-Model', 'claude-sonnet-5-5', '-MaxRunUsd', '1', '-MaxTotalUsd', '1'); want = 'ExpectVersion' }
    @{ name = 'no budget'; extra = @('-Model', 'claude-sonnet-5-5', '-ExpectVersion', '0.0.0-stub'); want = 'MaxRunUsd' }
    @{ name = 'a model the table cannot price'; extra = @('-Model', 'claude-future-9', '-ExpectVersion', '0.0.0-stub', '-MaxRunUsd', '1', '-MaxTotalUsd', '1'); want = 'no price' }
    @{ name = 'a different Claude Code version'; extra = @('-Model', 'claude-sonnet-5-5', '-ExpectVersion', '9.9.9', '-MaxRunUsd', '1', '-MaxTotalUsd', '1', '-OutDir', (Join-Path $script:Sandbox 'refused')); want = 'not the pinned' }
)
foreach ($c in $cases) {
    $r = Invoke-Ps $run ($liveBase + $c.extra)
    Check "a live run refuses $($c.name)" ($r.code -eq 2 -and $r.text -match $c.want) $r.text
}
Remove-Item Env:ANTHROPIC_API_KEY
$r = Invoke-Ps $run ($liveBase + @('-Model', 'claude-sonnet-5-5', '-ExpectVersion', '0.0.0-stub', '-MaxRunUsd', '1', '-MaxTotalUsd', '1'))
Check 'a live run refuses to start with no API key' ($r.code -eq 2 -and $r.text -match 'ANTHROPIC_API_KEY') $r.text
$calls = if (Test-Path -LiteralPath $log) { @([System.IO.File]::ReadAllLines($log) | Where-Object { $_.Trim() }) } else { @() }
Check 'no refused run reached a model step' ($calls.Count -eq 0) ($calls -join ' ')

Write-Section 'a full run, with known answers'
$env:ANTHROPIC_API_KEY = 'sk-ant-test-SYNTHETIC-benchmark-key-0123456789'
$env:CLAUDE_EFFORT = 'stray'
$env:ANTHROPIC_BASE_URL = 'http://stray.invalid'
$env:OPUS_TUNER_STATE_STRAY = 'stray'
$realConfig = $env:CLAUDE_CONFIG_DIR
$out = Join-Path $script:Sandbox 'results'
$pinned = Join-Path (Join-Path (Join-Path $PSScriptRoot 'fixtures') 'usage') 'pricing-pinned.json'
$r = Invoke-Ps $run @('-Stub', '-Tasks', 'ledger-rules,timeout-migration', '-Repeats', '2', '-Seed', '7', '-Pricing', $pinned, '-OutDir', $out)
Remove-Item Env:CLAUDE_EFFORT, Env:ANTHROPIC_BASE_URL, Env:OPUS_TUNER_STATE_STRAY
Check 'the run finishes' ($r.code -eq 0) $r.text
$manifest = [System.IO.File]::ReadAllText((Join-Path $out 'manifest.json')) | ConvertFrom-Json
Check 'the manifest marks it as not live' ($manifest.live -eq $false)
Check 'the manifest pins the model and version' ($manifest.model -eq 'claude-sonnet-5-5' -and $manifest.claudeVersion -match '0\.0\.0-stub')
Check 'the manifest records the seed and pricing version' ($manifest.seed -eq 7 -and [string]$manifest.pricingVersion)
$runs = @(Get-Runs $out)
Check '3 arms x 2 tasks x 2 repeats gives 12 runs' ($runs.Count -eq 12) "$($runs.Count)"
Check 'every run completed and passed' (@($runs | Where-Object { $_.status -eq 'completed' -and $_.passed -eq $true }).Count -eq 12) (($runs | ForEach-Object { "$($_.arm)/$($_.status)/$($_.passed)/$(@($_.failedChecks) -join ',')" }) -join ' | ')
$order = @($runs | ForEach-Object { "$($_.task)/$($_.arm)/$($_.repeat)" })
$sorted = @($order | Sort-Object)
Check 'the order is shuffled' (($order -join ',') -ne ($sorted -join ','))

# Per call, on sonnet 5.5: 100x2 + 1000x0.10 + 200x2.50 + 50x10 = 1300 per million.
$perCall = 0.0013
$perTokens = 1350
foreach ($arm in @('default', 'short', 'tuner')) {
    $group = @($runs | Where-Object { $_.arm -eq $arm })
    $callsWanted = if ($arm -eq 'default') { 3 } else { 4 }
    $first = $group[0]
    Check "${arm}: tokens are exact, and repeated records count once" ([int]$first.tokens.requests -eq $callsWanted -and ([int64]$first.tokens.input + [int64]$first.tokens.cacheRead + [int64]$first.tokens.cacheWrite + [int64]$first.tokens.output) -eq ($callsWanted * $perTokens)) "requests $($first.tokens.requests)"
    Check "${arm}: cost is exact" (Test-Near $first.costUSD ($callsWanted * $perCall)) "got $($first.costUSD)"
    Check "${arm}: repeated records are reported" ([int]$first.duplicateRecords -eq $callsWanted) "got $($first.duplicateRecords)"
    $sum = 0.0; foreach ($s in @($first.steps)) { $sum += [double]$s.costUSD }
    Check "${arm}: step costs add up to the run" (Test-Near $sum $first.costUSD) "$sum"
    Check "${arm}: all four facts are recalled" ([int]$first.facts.total -eq 4 -and @($first.facts.lost).Count -eq 0) "$($first.facts.total)"
    Check "${arm}: the recall step's cost counts as rebuilding" ([int64]$first.rebuild.tokens -eq $perTokens) "$($first.rebuild.tokens)"
    Check "${arm}: elapsed time is recorded" ([int64]$first.elapsedMs -gt 0)
}
$default = @($runs | Where-Object { $_.arm -eq 'default' })[0]
$short = @($runs | Where-Object { $_.arm -eq 'short' })[0]
$tuner = @($runs | Where-Object { $_.arm -eq 'tuner' })[0]
Check 'default has no handoff step or cost' ([int64]$default.handoffOverhead.tokens -eq 0 -and [int]$default.interruptions.continuations -eq 0)
Check 'default stays in one session' (@($default.steps | ForEach-Object { $_.session } | Sort-Object -Unique).Count -eq 1)
foreach ($pair in @(@('short', $short), @('tuner', $tuner))) {
    Check "$($pair[0]): the handoff's cost is counted" ([int64]$pair[1].handoffOverhead.tokens -eq $perTokens -and (Test-Near $pair[1].handoffOverhead.costUSD $perCall))
    Check "$($pair[0]): the handoff counts as an interruption" ([int]$pair[1].interruptions.continuations -eq 1)
    Check "$($pair[0]): work continues in a new session" (@($pair[1].steps | ForEach-Object { $_.session } | Sort-Object -Unique).Count -eq 2)
    Check "$($pair[0]): the repeated read after the handoff is counted" ([int]$pair[1].repeatedLookups -gt 0) "$($pair[1].repeatedLookups)"
}
Check 'short: its notes were written' ($short.handoff.written -eq $true)
Check 'tuner: its handoff was written, verified and picked up' ($tuner.handoff.written -eq $true -and $tuner.handoff.verified -eq $true -and $tuner.handoff.pickedUp -eq $true)

Write-Section 'isolation and comparability'
$calls = @([System.IO.File]::ReadAllLines($log) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
Check 'the stub was called' ($calls.Count -gt 0)
$configs = @($calls | ForEach-Object { $_.config } | Sort-Object -Unique)
Check 'each of the 12 runs has its own configuration' ($configs.Count -eq 12) "$($configs.Count)"
Check 'none of them is the caller''s' (@($configs | Where-Object { $_ -eq $realConfig }).Count -eq 0)
$cwds = @($calls | ForEach-Object { $_.cwd } | Sort-Object -Unique)
Check 'each run has its own workspace' ($cwds.Count -eq 12) "$($cwds.Count)"
Check 'stray settings do not reach a run' (@($calls | Where-Object { @($_.strayEnv).Count -gt 0 }).Count -eq 0) (@($calls | ForEach-Object { $_.strayEnv }) -join ',')
function Get-Shape {
    param($Call)
    $list = @($Call.args)
    $keep = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i] -eq '--session-id' -or $list[$i] -eq '--resume') { $i++; continue }
        [void]$keep.Add($list[$i])
    }
    return ($keep -join ' ')
}
$shapes = @($calls | ForEach-Object { Get-Shape $_ } | Sort-Object -Unique)
Check 'all arms use identical flags' ($shapes.Count -eq 1) ($shapes -join ' || ')
Check 'the flags pin the model, effort and permissions' ($shapes[0] -match '--model claude-sonnet-5-5' -and $shapes[0] -match '--effort high' -and $shapes[0] -match '--permission-mode dontAsk' -and $shapes[0] -match '--strict-mcp-config' -and $shapes[0] -match '--setting-sources user')
foreach ($taskName in @('ledger-rules', 'timeout-migration')) {
    $ranArms = @($runs | Where-Object { $_.task -eq $taskName } | ForEach-Object { $_.arm } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" } | Sort-Object) -join ','
    Check "$taskName ran equally under every arm" ($ranArms -eq 'default=2,short=2,tuner=2') $ranArms
}
$recallPrompts = @($calls | Where-Object { $_.step -eq 'recall' -and $_.arm -ne 'short' } | ForEach-Object { $_.prompt } | Sort-Object -Unique)
Check 'default and tuner get the same recall prompts' ($recallPrompts.Count -eq 2) "$($recallPrompts.Count)"
$shortRecall = @($calls | Where-Object { $_.step -eq 'recall' -and $_.arm -eq 'short' })[0]
Check 'short is pointed at its notes' ([string]$shortRecall.prompt -match 'HANDOFF\.md')
$everything = (Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
Check 'the API key is never written to the results' ($everything -notmatch 'SYNTHETIC-benchmark-key')
Remove-Item Env:ANTHROPIC_API_KEY

Write-Section 'each arm is set up as described'
$keep = Join-Path $script:Sandbox 'kept'
$r = Invoke-Ps $run @('-Stub', '-Arms', 'default,short,tuner,tuner-guard', '-Tasks', 'ledger-rules', '-Repeats', '1', '-KeepRuns', '-OutDir', $keep)
$roots = [regex]::Match($r.text, 'run directories kept: (.+)').Groups[1].Value.Trim()
Check 'run directories can be kept' ($roots -and (Test-Path -LiteralPath $roots)) $r.text
$kept = @(Get-Runs $keep)
foreach ($row in $kept) {
    $config = Join-Path (Join-Path $roots ('run-{0:000}' -f [int]$row.order)) 'config'
    $settings = Join-Path $config 'settings.json'
    $hasHooks = (Test-Path -LiteralPath $settings) -and ([System.IO.File]::ReadAllText($settings) -match 'session-start\.ps1')
    $hasMd = Test-Path -LiteralPath (Join-Path $config 'CLAUDE.md')
    $mdText = if ($hasMd) { [System.IO.File]::ReadAllText((Join-Path $config 'CLAUDE.md')) } else { '' }
    switch ($row.arm) {
        'default' {
            Check 'default has no hooks' (-not $hasHooks)
            Check 'default has no CLAUDE.md' (-not $hasMd)
        }
        'short' {
            Check 'short has no hooks' (-not $hasHooks)
            Check 'short has its instructions' ($mdText -match 'HANDOFF\.md')
        }
        'tuner' {
            Check 'tuner has its hooks' $hasHooks
            Check 'tuner is in assist mode' (([System.IO.File]::ReadAllText((Join-Path $config 'tuner.config.json')) | ConvertFrom-Json).mode -eq 'assist')
            Check 'tuner installed the wrap skill' (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $config 'skills') 'wrap') 'SKILL.md'))
        }
        'tuner-guard' {
            $c = [System.IO.File]::ReadAllText((Join-Path $config 'tuner.config.json')) | ConvertFrom-Json
            Check 'tuner-guard turns the interruptions on' ($c.mode -eq 'guard' -and $c.hardWrap -eq $true -and $c.blockManualCompact -eq $true)
        }
    }
}
Remove-Item -LiteralPath $roots -Recurse -Force -ErrorAction SilentlyContinue

Write-Section 'failures are recorded, not hidden'
$env:BENCH_STUB_FAIL = 'tuner:phase2'
$env:BENCH_STUB_UNSOLVED = 'short'
$env:BENCH_STUB_LOSE = 'default:integer-cents'
$bad = Join-Path $script:Sandbox 'bad'
$r = Invoke-Ps $run @('-Stub', '-Tasks', 'ledger-rules', '-Repeats', '1', '-OutDir', $bad)
Remove-Item Env:BENCH_STUB_FAIL, Env:BENCH_STUB_UNSOLVED, Env:BENCH_STUB_LOSE
$rows = @(Get-Runs $bad)
$t = @($rows | Where-Object { $_.arm -eq 'tuner' })[0]
Check 'a failed step stops that run and names itself' ($t.status -eq 'failed' -and $t.failedStep -eq 'phase2')
Check 'the failed run is still graded, and still costs' ($t.passed -eq $false -and [double]$t.costUSD -gt 0)
$s = @($rows | Where-Object { $_.arm -eq 'short' })[0]
Check 'work the grader rejects counts as incorrect' ($s.status -eq 'completed' -and $s.passed -eq $false -and @($s.failedChecks).Count -gt 0)
$d = @($rows | Where-Object { $_.arm -eq 'default' })[0]
Check 'a fact missing from the recall is reported' (@($d.facts.lost) -contains 'integer-cents')

$rep = Invoke-Ps (Join-Path $bench 'report.ps1') @('-Results', $bad)
Check 'the report runs' ($rep.code -eq 0) $rep.text
Check 'it lists the failed run' ($rep.text -match 'ledger-rules / tuner / repeat 1: status failed, stopped at phase2') $rep.text
Check 'it lists the incorrect run' ($rep.text -match 'ledger-rules / short / repeat 1: status completed, failed checks') $rep.text
Check 'it lists the lost fact' ($rep.text -match 'facts lost: integer-cents') $rep.text
Check 'it says stub data proves nothing' ($rep.text -match 'STUB DATA' -and $rep.text -match 'PENDING') $rep.text
Check 'it marks routing and blocking as pending' ($rep.text -match 'effort routing: \*\*pending\*\*' -and $rep.text -match 'blocking and the Stop prompt: \*\*pending\*\*') $rep.text
Check 'it warns about too few runs' ($rep.text -match '(?i)too few runs') $rep.text
Check 'it claims no winner' ($rep.text -notmatch '(?i)\b(wins?|winner|superior|saves? \d|better than)\b') $rep.text
Check 'it writes report.md and summary.json' ((Test-Path -LiteralPath (Join-Path $bad 'report.md')) -and (Test-Path -LiteralPath (Join-Path $bad 'summary.json')))
$sum = [System.IO.File]::ReadAllText((Join-Path $bad 'summary.json')) | ConvertFrom-Json
Check 'summary.json marks it pending' ($sum.pending -eq $true -and $sum.live -eq $false)

$env:BENCH_STUB_SCALE = '100000'
$over = Join-Path $script:Sandbox 'over'
$r = Invoke-Ps $run @('-Stub', '-Arms', 'default', '-Tasks', 'ledger-rules', '-Repeats', '2', '-MaxRunUsd', '50', '-MaxTotalUsd', '100', '-OutDir', $over)
$rows = @(Get-Runs $over)
Remove-Item Env:BENCH_STUB_SCALE
$status = ($rows | ForEach-Object { $_.status }) -join ','
Check 'the run budget stops a run after the step that passed it' ($rows.Count -eq 2 -and $rows[0].status -eq 'budget-exceeded' -and @($rows[0].steps).Count -eq 1) $status
Check 'the total budget stops later runs, and they are reported' ($rows.Count -eq 2 -and $rows[1].status -eq 'not-run') $status

Write-Section 'with no results'
$empty = Join-Path $script:Sandbox 'nothing-here'
New-Item -ItemType Directory -Force -Path $empty | Out-Null
$rep = Invoke-Ps (Join-Path $bench 'report.ps1') @('-Results', $empty)
Check 'the report says results are pending' ($rep.text -match 'PENDING' -and $rep.code -eq 0) $rep.text

Remove-Item Env:BENCH_STUB_LOG -ErrorAction SilentlyContinue
Complete-TestRun 'benchmark tests'
