# Runs equivalent tasks under each arm and records what happened. See README.md.
#
#   powershell -NoProfile -File benchmarks/run.ps1                 # print the plan, call nothing
#   powershell -NoProfile -File benchmarks/run.ps1 -Stub           # exercise the harness offline
#   powershell -NoProfile -File benchmarks/run.ps1 -AllowLive -Model claude-sonnet-5-5 `
#       -ExpectVersion 2.1.314 -MaxRunUsd 5 -MaxTotalUsd 40 -Repeats 5
#
# A live run spends real money, so nothing reaches a model without -AllowLive and
# an explicit model, tool version and budget.

[CmdletBinding()]
param(
    [string[]]$Arms = @('default', 'short', 'tuner'),
    [string[]]$Tasks = @(),
    [int]$Repeats = 3,
    # A full model id. An alias could change meaning between runs.
    [string]$Model = '',
    [string]$Effort = 'high',
    # What `claude --version` must report.
    [string]$ExpectVersion = '',
    [double]$MaxRunUsd = 0,
    [double]$MaxTotalUsd = 0,
    [int]$StepTimeoutSec = 900,
    [int]$Seed = 1,
    [string]$Pricing = '',
    [string]$ClaudePath = 'claude',
    [string]$OutDir = '',
    [switch]$AllowLive,
    [switch]$Stub,
    [switch]$KeepRuns
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $here
$scripts = Join-Path (Join-Path (Join-Path $repo 'skills') 'opus-tuner') 'scripts'
. (Join-Path $scripts '_pricing.ps1')

$interpreter = (Get-Process -Id $PID).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
# The same for every arm. Skill is here because the tuner's /wrap needs it; an arm
# with no skills simply has nothing to call.
$allowedTools = 'Read,Edit,Write,Grep,Glob,Skill,Bash,PowerShell'

function Stop-Refused {
    param([string]$Why)
    Write-Host "refused: $Why"
    exit 2
}

function Write-Json {
    param([string]$Path, $Object)
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 10), $utf8)
}

function Read-Json {
    param([string]$Path)
    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

$Arms = @($Arms | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Tasks = @($Tasks | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$armTable = (Read-Json (Join-Path $here 'arms.json')).arms
foreach ($a in $Arms) {
    if (-not $armTable.PSObject.Properties[$a]) { Stop-Refused "unknown arm '$a'. Known: $(@($armTable.PSObject.Properties.Name) -join ', ')" }
}
$taskRoot = Join-Path $here 'tasks'
$known = @(Get-ChildItem -LiteralPath $taskRoot -Directory | ForEach-Object { $_.Name } | Sort-Object)
if ($Tasks.Count -eq 0) { $Tasks = $known }
foreach ($t in $Tasks) {
    if ($known -notcontains $t) { Stop-Refused "unknown task '$t'. Known: $($known -join ', ')" }
}

# Stub mode has its own fixed answers, so its runs can be checked to the cent.
if ($Stub) {
    if ($ClaudePath -eq 'claude') { $ClaudePath = Join-Path (Join-Path $here 'stub') 'claude-stub.ps1' }
    if (-not $Model) { $Model = 'claude-sonnet-5-5' }
    if (-not $ExpectVersion) { $ExpectVersion = '0.0.0-stub' }
    if ($MaxRunUsd -le 0) { $MaxRunUsd = 100 }
    if ($MaxTotalUsd -le 0) { $MaxTotalUsd = 1000 }
}

$jobs = New-Object System.Collections.ArrayList
foreach ($t in $Tasks) {
    foreach ($a in $Arms) {
        for ($n = 1; $n -le $Repeats; $n++) { [void]$jobs.Add(@{ task = $t; arm = $a; repeat = $n }) }
    }
}
# Shuffled so that an arm does not always run at the same time of day, or straight
# after the same neighbour.
$rng = New-Object System.Random($Seed)
for ($i = $jobs.Count - 1; $i -gt 0; $i--) {
    $j = $rng.Next($i + 1)
    $swap = $jobs[$i]; $jobs[$i] = $jobs[$j]; $jobs[$j] = $swap
}

if (-not $AllowLive -and -not $Stub) {
    "benchmark plan. Nothing was run and no model was called."
    "  arms    : $($Arms -join ', ')"
    "  tasks   : $($Tasks -join ', ')"
    "  repeats : $Repeats, so $($jobs.Count) run(s)"
    ''
    'to run offline against the stub:  -Stub'
    'to spend money on a live run:     -AllowLive -Model <full id> -ExpectVersion <version> -MaxRunUsd <n> -MaxTotalUsd <n>'
    exit 0
}

if ($Model -notmatch '^claude-[a-z0-9-]*\d[a-z0-9-]*$') { Stop-Refused "-Model needs a full model id such as claude-sonnet-5-5, not '$Model'." }
if (-not $ExpectVersion) { Stop-Refused '-ExpectVersion is required, to pin the Claude Code version.' }
if ($MaxRunUsd -le 0 -or $MaxTotalUsd -le 0) { Stop-Refused '-MaxRunUsd and -MaxTotalUsd are required, so a run cannot spend without limit.' }
if ($AllowLive -and -not $Stub -and -not $env:ANTHROPIC_API_KEY) {
    Stop-Refused 'ANTHROPIC_API_KEY is not set. Each run has an empty configuration, so it cannot use a saved login. The key is passed through and never recorded.'
}

$table = Get-PricingTable -Path $Pricing
if (-not $table) { Stop-Refused $script:PricingError }
$pricedAs = ConvertTo-PricingModel $Model $table
if (-not $table.models.PSObject.Properties[$pricedAs]) { Stop-Refused "the pricing table has no price for $Model, so the budget could not be enforced." }
$pricingFile = if ($Pricing) { $Pricing } else { Join-Path (Join-Path (Split-Path -Parent $scripts) 'references') 'pricing.json' }

# How to start Claude Code, or the stub standing in for it.
$launch = @{ file = $ClaudePath; prefix = @() }
if ($ClaudePath -like '*.ps1') {
    $launch = @{ file = $interpreter; prefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ClaudePath) }
} elseif (-not (Test-Path -LiteralPath $ClaudePath)) {
    $found = Get-Command $ClaudePath -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { Stop-Refused "cannot find $ClaudePath" }
    $launch.file = $found.Source
}

function Join-Arguments {
    param([string[]]$List)
    return (@($List | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' ')
}

# Every Claude Code, Anthropic and tuner setting from this shell is removed, so a
# run sees only its own empty configuration and cannot reach the real ~/.claude.
# The API key passes through because a live run needs it, and is never written down.
function Enter-Isolation {
    param([string]$ConfigDir, [hashtable]$Extra = @{})
    $saved = @{}
    foreach ($v in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(CLAUDE|ANTHROPIC_|OPUS_TUNER|DISABLE_AUTOUPDATER)' })) {
        if ($v.Name -eq 'ANTHROPIC_API_KEY' -or $v.Name -eq 'CLAUDE_CODE_GIT_BASH_PATH') { continue }
        $saved[$v.Name] = $v.Value
        Remove-Item -LiteralPath "Env:$($v.Name)"
    }
    $env:CLAUDE_CONFIG_DIR = $ConfigDir
    $env:DISABLE_AUTOUPDATER = '1'
    foreach ($k in $Extra.Keys) {
        $saved["+$k"] = $true
        Set-Item -LiteralPath "Env:$k" -Value $Extra[$k]
    }
    return $saved
}

function Exit-Isolation {
    param([hashtable]$Saved)
    Remove-Item Env:CLAUDE_CONFIG_DIR, Env:DISABLE_AUTOUPDATER -ErrorAction SilentlyContinue
    foreach ($k in $Saved.Keys) {
        if ($k.StartsWith('+')) { Remove-Item -LiteralPath "Env:$($k.Substring(1))" -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath "Env:$k" -Value $Saved[$k] }
    }
}

# Runs one process with its stdin, stdout and stderr in files, under a time limit.
function Invoke-Timed {
    param([string]$File, [string[]]$Arguments, [string]$WorkDir, [string]$InputFile, [string]$OutFile, [string]$ErrFile, [int]$TimeoutSec)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $File -ArgumentList (Join-Arguments $Arguments) -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
        -RedirectStandardInput $InputFile -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile
    # Windows PowerShell loses the exit code unless the handle is read first.
    $null = $p.Handle
    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        if ($script:IsWindowsHost) { & taskkill /PID $p.Id /T /F 2>$null | Out-Null }
        else { try { $p.Kill() } catch { } }
        $null = $p.WaitForExit(5000)
    }
    $clock.Stop()
    return @{ code = $(if ($finished) { $p.ExitCode } else { -1 }); timedOut = (-not $finished); elapsedMs = $clock.ElapsedMilliseconds }
}
$script:IsWindowsHost = ([System.IO.Path]::DirectorySeparatorChar -eq '\')

# A throwaway helper script in the run's own process, for task setup and grading.
function Invoke-TaskScript {
    param([string]$Script, [string[]]$Arguments)
    # Windows PowerShell turns a child's stderr into a terminating error under Stop.
    $ErrorActionPreference = 'Continue'
    return (& $interpreter -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String)
}

# Cumulative tokens and cost, from the audit itself, so these figures and a user's
# own audit can never disagree. A step's share is the change since the last call.
function Get-RunUsage {
    $text = Invoke-TaskScript (Join-Path $scripts 'audit.ps1') @('-Recent', '0', '-Json', '-Pricing', $pricingFile)
    $u = @{ input = [int64]0; cacheRead = [int64]0; cacheWrite = [int64]0; output = [int64]0; requests = 0; cost = [decimal]0; unknownRequests = 0; duplicates = 0 }
    if ($text -notmatch '^\s*\{') { return $u }
    $j = $text | ConvertFrom-Json
    $u.input = [int64]$j.totals.input
    $u.cacheRead = [int64]$j.totals.cacheRead
    $u.cacheWrite = [int64]$j.totals.cacheWrite
    $u.output = [int64]$j.totals.output
    $u.requests = [int]$j.totals.requests
    $u.cost = [decimal]$j.totals.costUSD
    $u.unknownRequests = [int]$j.unknownPricing.requests
    $u.duplicates = [int]$j.duplicateRecords
    return $u
}

# The read and search calls in a run's transcripts that have not been seen yet.
function Get-NewLookups {
    param([string]$ConfigDir, [hashtable]$Seen)
    $found = New-Object System.Collections.ArrayList
    $projects = Join-Path $ConfigDir 'projects'
    if (-not (Test-Path -LiteralPath $projects)) { return ,$found }
    foreach ($f in @(Get-ChildItem -LiteralPath $projects -Recurse -Filter '*.jsonl')) {
        foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
            if ($line.IndexOf('"tool_use"') -lt 0) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            foreach ($b in @($o.message.content)) {
                if ($null -eq $b -or [string]$b.type -ne 'tool_use' -or -not $b.id -or $Seen.ContainsKey([string]$b.id)) { continue }
                $Seen[[string]$b.id] = $true
                if (@('Read', 'Grep', 'Glob') -notcontains [string]$b.name) { continue }
                $what = if ($b.input.file_path) { [string]$b.input.file_path } else { [string]$b.input.pattern }
                [void]$found.Add("$($b.name):$what")
            }
        }
    }
    return ,$found
}

function Get-DecisionCount {
    param([string]$ConfigDir, [string]$Action)
    $log = Join-Path (Join-Path (Join-Path $ConfigDir 'state') 'tuner') 'decisions.csv'
    if (-not (Test-Path -LiteralPath $log)) { return 0 }
    return @(Import-Csv -LiteralPath $log | Where-Object { $_.action -eq $Action }).Count
}

# ---------- one run ----------
function Invoke-BenchmarkRun {
    param([hashtable]$Job, [string]$RunRoot, [int]$Index)
    $arm = $armTable.PSObject.Properties[$Job.arm].Value
    $taskDir = Join-Path $taskRoot $Job.task
    $task = Read-Json (Join-Path $taskDir 'task.json')

    $runDir = Join-Path $RunRoot ('run-{0:000}' -f $Index)
    $configDir = Join-Path $runDir 'config'
    $workspace = Join-Path $runDir 'workspace'
    $logs = Join-Path $runDir 'logs'
    foreach ($d in @($configDir, $workspace, $logs)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

    $result = [ordered]@{
        task = $Job.task; arm = $Job.arm; repeat = $Job.repeat; order = $Index; status = 'completed'; failedStep = ''
        passed = $false; failedChecks = @(); steps = @()
        tokens = $null; costUSD = $null; unknownRequests = 0; duplicateRecords = 0; elapsedMs = [int64]0
        handoffOverhead = @{ tokens = [int64]0; costUSD = [decimal]0; elapsedMs = [int64]0 }
        rebuild = @{ tokens = [int64]0; costUSD = [decimal]0; elapsedMs = [int64]0 }
        interruptions = @{ continuations = 0; stopPrompts = 0; blockedCompactions = 0; permissionDenials = 0 }
        facts = @{ total = 0; lost = @() }
        repeatedLookups = 0; lookups = 0
        handoff = @{ written = $null; verified = $null; pickedUp = $null }
    }

    $null = Invoke-TaskScript (Join-Path $taskDir 'setup.ps1') @('-Path', $workspace)

    $extra = @{}
    if ($Stub) { $extra = @{ BENCH_STUB_ARM = $Job.arm; BENCH_STUB_TASKDIR = $taskDir; BENCH_STUB_STEP = '' } }
    $saved = Enter-Isolation $configDir $extra
    try {
        if ($arm.claudeMd) {
            Copy-Item -LiteralPath (Join-Path $here $arm.claudeMd) -Destination (Join-Path $configDir 'CLAUDE.md')
        }
        if ($arm.tuner) {
            $out = Invoke-TaskScript (Join-Path $repo 'install.ps1') @('-Force', '-NoStatusLine')
            [System.IO.File]::WriteAllText((Join-Path $logs 'install.txt'), $out, $utf8)
            Write-Json (Join-Path $configDir 'tuner.config.json') $arm.tuner
        }

        $session = [guid]::NewGuid().ToString()
        $fresh = $true
        $prefix = ''
        $before = Get-RunUsage
        $seenTools = @{}
        $earlierLookups = @{}
        $continued = $false
        $stepRows = New-Object System.Collections.ArrayList
        $writer = ''

        foreach ($step in @($task.steps)) {
            $kind = [string]$step.kind
            if ($kind -eq 'continuation') {
                if ([string]$arm.continuation -eq 'resume') { $continued = $true; continue }
                $prompt = [string]$arm.handoffPrompt
                $stepId = 'handoff'
            } else {
                $prompt = $prefix + [string]$step.prompt
                $stepId = [string]$step.id
                $prefix = ''
            }

            $promptFile = Join-Path $logs "$stepId.in.txt"
            $outFile = Join-Path $logs "$stepId.out.json"
            $errFile = Join-Path $logs "$stepId.err.txt"
            [System.IO.File]::WriteAllText($promptFile, $prompt, $utf8)
            $cliArgs = @($launch.prefix) + @(
                '-p', '--output-format', 'json', '--model', $Model, '--effort', $Effort,
                '--permission-mode', 'dontAsk', '--allowedTools', $allowedTools,
                '--setting-sources', 'user', '--strict-mcp-config',
                '--max-budget-usd', $MaxRunUsd.ToString($invariant)
            )
            if ($fresh) { $cliArgs += @('--session-id', $session) } else { $cliArgs += @('--resume', $session) }
            if ($Stub) { $env:BENCH_STUB_STEP = $stepId }

            $ran = Invoke-Timed -File $launch.file -Arguments $cliArgs -WorkDir $workspace -InputFile $promptFile -OutFile $outFile -ErrFile $errFile -TimeoutSec $StepTimeoutSec
            $fresh = $false

            $reply = $null
            try {
                $reply = [System.IO.File]::ReadAllText($outFile) | ConvertFrom-Json
                if ($reply -is [array]) { $reply = @($reply | Where-Object { $_.type -eq 'result' })[-1] }
            } catch { }
            $answer = if ($reply) { [string]$reply.result } else { '' }
            $bad = ($ran.timedOut -or $ran.code -ne 0 -or $null -eq $reply -or $reply.is_error -eq $true)
            if ($reply -and $reply.permission_denials) { $result.interruptions.permissionDenials += @($reply.permission_denials).Count }

            $now = Get-RunUsage
            $tokens = ($now.input + $now.cacheRead + $now.cacheWrite + $now.output) - ($before.input + $before.cacheRead + $before.cacheWrite + $before.output)
            $cost = $now.cost - $before.cost
            $looked = Get-NewLookups $configDir $seenTools
            $repeats = 0
            foreach ($l in $looked) {
                if ($continued -and $earlierLookups.ContainsKey($l)) { $repeats++ }
            }
            if (-not $continued) { foreach ($l in $looked) { $earlierLookups[$l] = $true } }
            $result.lookups += $looked.Count
            $result.repeatedLookups += $repeats

            [void]$stepRows.Add([ordered]@{
                id = $stepId; kind = $kind; session = $session; newSession = ($cliArgs -contains '--session-id')
                exitCode = $ran.code; timedOut = $ran.timedOut; elapsedMs = $ran.elapsedMs
                tokens = $tokens; requests = ($now.requests - $before.requests); costUSD = $cost; repeatedLookups = $repeats
            })
            $result.elapsedMs += $ran.elapsedMs
            $before = $now

            if ($kind -eq 'continuation') {
                $result.handoffOverhead.tokens += $tokens
                $result.handoffOverhead.costUSD += $cost
                $result.handoffOverhead.elapsedMs += $ran.elapsedMs
                $result.interruptions.continuations++
                if ([string]$arm.continuation -eq 'notes') {
                    $result.handoff.written = (Test-Path -LiteralPath (Join-Path $workspace 'HANDOFF.md'))
                } else {
                    $h = Join-Path (Join-Path (Join-Path (Join-Path $configDir 'state') 'tuner') 'handoffs') "$session.md"
                    $result.handoff.written = (Test-Path -LiteralPath $h)
                    $result.handoff.verified = ($result.handoff.written -and ([System.IO.File]::ReadAllText($h) -match '(?m)^status:\s*ready\s*$'))
                    $writer = $session
                }
                # What a user does next: /clear, or quit and start again. Print mode
                # has no /clear, and a new session here takes the same startup path
                # the session-start hook uses once the writer has ended.
                $session = [guid]::NewGuid().ToString()
                $fresh = $true
                $continued = $true
                $prefix = [string]$arm.freshPrefix
            }
            if ($kind -eq 'recall') {
                $result.rebuild.tokens += $tokens
                $result.rebuild.costUSD += $cost
                $result.rebuild.elapsedMs += $ran.elapsedMs
                $lost = @()
                foreach ($fact in @($step.facts)) {
                    $result.facts.total++
                    if ($answer -notmatch [string]$fact.pattern) { $lost += [string]$fact.id }
                }
                $result.facts.lost = $lost
                if ($answer.Length -gt 4000) { $answer = $answer.Substring(0, 4000) }
                $result['recallAnswer'] = $answer
                if ($writer) {
                    $consumed = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $configDir 'state') 'tuner') 'handoffs') 'consumed') "$writer.md"
                    $result.handoff.pickedUp = (Test-Path -LiteralPath $consumed)
                }
            }

            if ($bad) {
                $result.status = 'failed'
                $result.failedStep = $stepId
                break
            }
            if ([double]$now.cost -gt $MaxRunUsd) {
                $result.status = 'budget-exceeded'
                $result.failedStep = $stepId
                break
            }
        }

        $result.steps = @($stepRows)
        $usage = Get-RunUsage
        $result.tokens = @{ input = $usage.input; cacheRead = $usage.cacheRead; cacheWrite = $usage.cacheWrite; output = $usage.output; requests = $usage.requests }
        $result.costUSD = $usage.cost
        $result.unknownRequests = $usage.unknownRequests
        $result.duplicateRecords = $usage.duplicates
        $result.interruptions.stopPrompts = Get-DecisionCount $configDir 'hard-wrap'
        $result.interruptions.blockedCompactions = Get-DecisionCount $configDir 'compact-blocked'
    } finally {
        Exit-Isolation $saved
    }

    # Graded the same way whatever happened, so a failed run still shows what it got done.
    $graded = $null
    try { $graded = (Invoke-TaskScript (Join-Path $taskDir 'check.ps1') @('-Path', $workspace)) | ConvertFrom-Json } catch { }
    if ($graded) {
        $result.passed = ($graded.passed -eq $true)
        $result.failedChecks = @(@($graded.checks) | Where-Object { -not $_.ok } | ForEach-Object { [string]$_.name })
    } else {
        $result.failedChecks = @('the checker did not run')
    }
    return $result
}

# ---------- all runs ----------
$live = -not $Stub
$versionFile = Join-Path (Split-Path -Parent $scripts) 'VERSION'
$tunerVersion = if (Test-Path -LiteralPath $versionFile) { ([System.IO.File]::ReadAllText($versionFile)).Trim() } else { 'unknown' }
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $here 'results') $stamp }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$runRoot = Join-Path ([System.IO.Path]::GetTempPath()) "opus-tuner-bench-$stamp-$PID"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

$saved = Enter-Isolation (Join-Path $runRoot 'version-probe')
try {
    $probe = Join-Path $runRoot 'version.txt'
    $none = Join-Path $runRoot 'empty.txt'
    [System.IO.File]::WriteAllText($none, '', $utf8)
    $null = Invoke-Timed -File $launch.file -Arguments (@($launch.prefix) + @('--version')) -WorkDir $runRoot -InputFile $none -OutFile $probe -ErrFile (Join-Path $runRoot 'version.err.txt') -TimeoutSec 60
    $claudeVersion = ([System.IO.File]::ReadAllText($probe)).Trim()
} finally { Exit-Isolation $saved }
if (-not $claudeVersion.StartsWith($ExpectVersion)) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Refused "Claude Code reports '$claudeVersion', not the pinned $ExpectVersion."
}

$commit = ''
try { $commit = (& git -C $repo rev-parse HEAD 2>$null | Select-Object -First 1) } catch { }
Write-Json (Join-Path $OutDir 'manifest.json') ([ordered]@{
    live = $live; started = (Get-Date).ToString('o'); claudeVersion = $claudeVersion; model = $Model; effort = $Effort
    allowedTools = $allowedTools; permissionMode = 'dontAsk'; maxRunUsd = $MaxRunUsd; maxTotalUsd = $MaxTotalUsd; stepTimeoutSec = $StepTimeoutSec
    arms = $Arms; tasks = $Tasks; repeats = $Repeats; seed = $Seed; pricingVersion = [string]$table.version
    tunerVersion = $tunerVersion; repoCommit = $commit; platform = [string][System.Environment]::OSVersion; powershell = $PSVersionTable.PSVersion.ToString()
})

$runsFile = Join-Path $OutDir 'runs.jsonl'
$spent = [decimal]0
$index = 0
foreach ($job in $jobs) {
    $index++
    if ([double]$spent -ge $MaxTotalUsd) {
        $row = [ordered]@{ task = $job.task; arm = $job.arm; repeat = $job.repeat; order = $index; status = 'not-run'; failedStep = ''; passed = $false; failedChecks = @('the total budget ran out first') }
    } else {
        Write-Host ("[{0}/{1}] {2} / {3} / repeat {4}" -f $index, $jobs.Count, $job.task, $job.arm, $job.repeat)
        try {
            $row = Invoke-BenchmarkRun -Job $job -RunRoot $runRoot -Index $index
            $spent += [decimal]$row.costUSD
        } catch {
            $row = [ordered]@{ task = $job.task; arm = $job.arm; repeat = $job.repeat; order = $index; status = 'harness-error'; failedStep = ''; passed = $false; failedChecks = @($_.Exception.Message) }
        }
    }
    [System.IO.File]::AppendAllText($runsFile, ($row | ConvertTo-Json -Depth 10 -Compress) + "`n", $utf8)
}

if (-not $KeepRuns) { Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue }
else { "run directories kept: $runRoot" }

"results: $OutDir"
if ($live) { "api-equivalent estimate for these runs: `$$($spent.ToString('N2'))" }
"next: powershell -NoProfile -File benchmarks/report.ps1 -Results `"$OutDir`""
exit 0
