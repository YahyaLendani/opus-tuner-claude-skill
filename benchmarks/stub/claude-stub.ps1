# Stands in for `claude` so the harness can be tested offline. It never reaches a
# model. Each call writes a known usage record to the run's isolated transcript, and
# does the step's work with the task's reference solution.
#
#   BENCH_STUB_ARM, _TASKDIR, _STEP  set by run.ps1 -Stub
#   BENCH_STUB_LOG                   a file to append each call's arguments to
#   BENCH_STUB_FAIL=arm:step         exit 1 on that step
#   BENCH_STUB_UNSOLVED=arm          skip the work, so the grader should fail it
#   BENCH_STUB_VIOLATE=arm           do the work but break the task's rules
#   BENCH_STUB_LOSE=arm:fact         leave that fact out of the recall answer
#   BENCH_STUB_SCALE=n               multiply the usage, for budget tests

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$list = @($args)

if ($list -contains '--version') {
    '0.0.0-stub (Claude Code)'
    exit 0
}

function Get-Flag {
    param([string]$Name)
    $at = [array]::IndexOf($list, $Name)
    if ($at -ge 0 -and ($at + 1) -lt $list.Count) { return [string]$list[$at + 1] }
    return ''
}

$arm = [string]$env:BENCH_STUB_ARM
$stepId = [string]$env:BENCH_STUB_STEP
$config = [string]$env:CLAUDE_CONFIG_DIR
$session = Get-Flag '--session-id'
if (-not $session) { $session = Get-Flag '--resume' }
$prompt = [Console]::In.ReadToEnd()

if ($env:BENCH_STUB_LOG) {
    $line = [ordered]@{
        arm = $arm; step = $stepId; args = @($list); config = $config; cwd = (Get-Location).Path; prompt = $prompt
        strayEnv = @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(CLAUDE_EFFORT|ANTHROPIC_BASE_URL|ANTHROPIC_MODEL|OPUS_TUNER_)' } | ForEach-Object { $_.Name })
    } | ConvertTo-Json -Compress -Depth 5
    [System.IO.File]::AppendAllText($env:BENCH_STUB_LOG, $line + "`n", $utf8)
}

if ($env:BENCH_STUB_FAIL -eq "${arm}:$stepId") {
    '{"type":"result","is_error":true,"result":"stub failure"}'
    exit 1
}

# A start after a verified handoff takes it, as session-start.ps1 would.
$state = Join-Path (Join-Path $config 'state') 'tuner'
$handoffs = Join-Path $state 'handoffs'
if ((Get-Flag '--session-id') -and (Test-Path -LiteralPath $handoffs)) {
    $consumed = Join-Path $handoffs 'consumed'
    New-Item -ItemType Directory -Force -Path $consumed | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $handoffs -Filter '*.md')) {
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $consumed $f.Name) -Force
    }
}

$project = Join-Path (Join-Path $config 'projects') 'stub-project'
New-Item -ItemType Directory -Force -Path $project | Out-Null
$transcript = Join-Path $project "$session.jsonl"
$scale = 1
if ($env:BENCH_STUB_SCALE) { $scale = [int]$env:BENCH_STUB_SCALE }
$model = Get-Flag '--model'
$id = "msg_$($stepId)_$([guid]::NewGuid().ToString('N'))"
$record = [ordered]@{
    type = 'assistant'; uuid = [guid]::NewGuid().ToString(); requestId = "req_$id"; sessionId = $session; isSidechain = $false
    message = [ordered]@{
        id = $id; model = $model
        content = @(@{ type = 'tool_use'; id = "toolu_$id"; name = 'Read'; input = @{ file_path = 'NOTES.txt' } })
        usage = [ordered]@{
            input_tokens = 100 * $scale; cache_read_input_tokens = 1000 * $scale; cache_creation_input_tokens = 200 * $scale
            cache_creation = @{ ephemeral_5m_input_tokens = 200 * $scale; ephemeral_1h_input_tokens = 0 }
            output_tokens = 50 * $scale
        }
    }
} | ConvertTo-Json -Compress -Depth 8
# Written twice, as a real transcript repeats a message's usage across its lines.
[System.IO.File]::AppendAllText($transcript, $record + "`n" + $record + "`n", $utf8)

$answer = 'done'
$taskDir = [string]$env:BENCH_STUB_TASKDIR
$task = [System.IO.File]::ReadAllText((Join-Path $taskDir 'task.json')) | ConvertFrom-Json
$step = @($task.steps | Where-Object { [string]$_.id -eq $stepId })

if ($stepId -eq 'handoff') {
    if ($prompt.Trim() -eq '/wrap') {
        New-Item -ItemType Directory -Force -Path $handoffs | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $handoffs "$session.md"), "---`nsession_id: $session`nstatus: ready`n---`nstub handoff`n", $utf8)
    } else {
        [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path 'HANDOFF.md'), "stub notes`n", $utf8)
    }
} elseif ($step.Count -eq 1 -and [string]$step[0].kind -eq 'recall') {
    $parts = @()
    foreach ($fact in @($step[0].facts)) {
        if ($env:BENCH_STUB_LOSE -eq "${arm}:$($fact.id)") { continue }
        $parts += [string]$fact.sample
    }
    $answer = $parts -join ' '
} elseif ($step.Count -eq 1 -and $env:BENCH_STUB_UNSOLVED -ne $arm) {
    $solver = Join-Path $taskDir 'solve.ps1'
    $interpreter = (Get-Process -Id $PID).Path
    $solveArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $solver, '-Path', (Get-Location).Path, '-Step', $stepId)
    if ($env:BENCH_STUB_VIOLATE -eq $arm) { $solveArgs += '-Violate' }
    $null = & $interpreter @solveArgs
}

[ordered]@{ type = 'result'; is_error = $false; result = $answer; session_id = $session; permission_denials = @() } | ConvertTo-Json -Compress -Depth 4
exit 0
