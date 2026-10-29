# Self-test for opus-tuner. Exercises every hook and skill script end to end
# against a synthetic transcript, so nothing writes into a real project.
#
#   powershell -NoProfile -File selftest.ps1
#   powershell -NoProfile -File selftest.ps1 -Interpreter powershell.exe
#
# Exits 0 when everything passes, 1 when anything fails.

param(
    [string]$Interpreter = '',
    # Generous on purpose. A hook costs ~440-490 ms on an idle machine, and the
    # spread between runs is tens of ms, so a 500 ms gate fails on a busy laptop
    # without indicating a regression. This gate is for "someone made the hook
    # 2x slower", not for noise. Pass a tighter value when measuring on purpose.
    [int]$BudgetMs = 750
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('opus-tuner-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
# Keep every state file and decision row out of the live directories. This has to
# be set before _common.ps1 is loaded, because it captures the path at dot-source.
$env:OPUS_TUNER_STATE = Join-Path $sandbox 'state'
New-Item -ItemType Directory -Force -Path $env:OPUS_TUNER_STATE | Out-Null
# Same for the config: an empty object means built-in defaults, so a developer
# who switched their live install to the creative profile (or changed a
# ceiling) gets the same results as CI. Tests that need a setting point at
# their own file and restore this one afterwards.
$script:BaseConfig = Join-Path $sandbox 'base.json'
[System.IO.File]::WriteAllText($script:BaseConfig, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
$env:OPUS_TUNER_CONFIG = $script:BaseConfig
# The weekly digest fires on the first fresh start once a decision log exists.
# Mark it as already shown, so only the test that wants it sees it.
[System.IO.File]::WriteAllText((Join-Path $env:OPUS_TUNER_STATE 'digest.stamp'), 'test', (New-Object System.Text.UTF8Encoding($false)))

. (Join-Path $here '_common.ps1')

# Guard: if the isolation override did not take effect, every hook below would
# write fake sessions into the live state directory. Refuse rather than litter.
$liveState = Join-Path (Join-Path $script:TunerRoot 'state') 'tuner'
if ($script:TunerState -eq $liveState) {
    Write-Host 'refusing to run: OPUS_TUNER_STATE was not set before _common.ps1 was loaded' -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Interpreter)) {
    $Interpreter = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
}

# -ExecutionPolicy only exists on Windows. Passing it to pwsh on macOS or Linux
# fails before the script runs, so build the prefix once.
$script:ExePrefix = @('-NoProfile')
if ($script:OnWindows) { $script:ExePrefix += @('-ExecutionPolicy', 'Bypass') }

# What does the interpreter cost before any hook logic runs? On a shared CI
# runner that cold start dominates the measurement (macOS measured 3.1 s for a
# hook whose own work is ~20 ms), so the timing gate below compares the hook
# against this floor instead of against zero. Three runs, minimum: the first
# pays for cold-start, the rest approximate the warm cost.
$noop = Join-Path $sandbox 'noop.ps1'
[System.IO.File]::WriteAllText($noop, "exit 0`n", (New-Object System.Text.UTF8Encoding($false)))
$noopRuns = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 3; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = & $Interpreter @ExePrefix -File $noop 2>&1
    $sw.Stop()
    [void]$noopRuns.Add([int]$sw.ElapsedMilliseconds)
}
$script:BaselineMs = ($noopRuns | Measure-Object -Minimum).Minimum

$startedAt = (Get-Date).AddSeconds(-1)

$pass = 0
$fail = 0
$timings = New-Object System.Collections.ArrayList
$createdStates = New-Object System.Collections.ArrayList

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red
    }
}

function Invoke-Hook {
    param([string]$Script, [string]$Payload)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = $Payload | & $Interpreter @ExePrefix -File (Join-Path $here $Script) 2>&1
    $sw.Stop()
    $text = ($out | Where-Object { $_ -is [string] }) -join "`n"
    return @{ text = $text.Trim(); ms = $sw.ElapsedMilliseconds }
}

function New-Payload {
    param([string]$Sid, [string]$Transcript, [string]$Prompt = '', [string]$Mode = 'default', [string]$Event = 'UserPromptSubmit', [bool]$StopActive = $false)
    return (@{
        session_id      = $Sid
        cwd             = $sandbox
        transcript_path = $Transcript
        permission_mode = $Mode
        hook_event_name = $Event
        prompt          = $Prompt
        stop_hook_active = $StopActive
    } | ConvertTo-Json -Compress)
}

function Write-FakeTranscript {
    param([string]$Name, [int]$CtxTokens)
    $p = Join-Path $sandbox $Name
    $line = '{"type":"assistant","message":{"model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":' + $CtxTokens + ',"cache_creation_input_tokens":0,"output_tokens":300}}}'
    [System.IO.File]::WriteAllText($p, $line, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

function New-Sid {
    $sid = 'st-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
    [void]$script:createdStates.Add($sid)
    return $sid
}

$small = Write-FakeTranscript 'ctx-80k.jsonl' 80000
$mid = Write-FakeTranscript 'ctx-120k.jsonl' 120000
$large = Write-FakeTranscript 'ctx-160k.jsonl' 160000
$over = Write-FakeTranscript 'ctx-260k.jsonl' 260000

Write-Host ''
Write-Host "opus-tuner self-test  (interpreter: $Interpreter)" -ForegroundColor Cyan
Write-Host "sandbox: $sandbox"
Write-Host ''

# ---------- 1. routing ----------
Write-Host 'routing' -ForegroundColor Yellow

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $mid 'rename all the variables in the codebase')
[void]$timings.Add([pscustomobject]@{ name = 'route'; ms = $r.ms })
$ok = $r.text.StartsWith('{')
Check 'mechanical+bulk emits valid JSON' $ok $r.text
Check 'mechanical+bulk routes to gear-low' ($r.text -match 'gear=low') $r.text

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $mid 'rename this function')
Check 'mechanical without bulk stays silent at 120k' ($r.text.Length -eq 0) $r.text

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small 'why does the auth race condition happen only under load, find the root cause')
Check 'hard prompt escalates tier to deep' ($r.text -match 'tier=deep') $r.text
Check 'hard prompt routes to gear-xhigh' ($r.text -match 'gear=xhigh') $r.text

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small 'what does this function do')
Check 'trivial prompt stays silent' ($r.text.Length -eq 0) $r.text

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $large 'carry on')
Check 'grace escalates instead of wrapping' ($r.text -match 'tier=deep \(grace\)' -and $r.text -notmatch '/clear') $r.text

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $over 'carry on')
Check 'prompt at the ceiling demands a wrap' ($r.text -match 'ceiling' -and $r.text -match '/clear') $r.text

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small 'help me plan the migration' 'plan')
Check 'plan mode escalates to deep' ($r.text -match 'tier=deep') $r.text

# ---------- 2. usage parsing ----------
Write-Host ''
Write-Host 'usage parsing (regression: nested and duplicated usage objects)' -ForegroundColor Yellow

$nested = Join-Path $sandbox 'ctx-nested.jsonl'
$nestedLine = '{"type":"assistant","message":{"model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":781,"cache_read_input_tokens":700000,"output_tokens":461,"output_tokens_details":{"thinking_tokens":156},"server_tool_use":{"web_search_requests":0,"fetch_requests":0},"cache_creation":{"ephemeral_1h_input_tokens":781,"ephemeral_5m_input_tokens":0},"iterations":[{"input_tokens":2,"output_tokens":461,"cache_read_input_tokens":700000,"cache_creation_input_tokens":781}]}}}'
[System.IO.File]::WriteAllText($nested, $nestedLine, (New-Object System.Text.UTF8Encoding($false)))
$info = Get-ContextInfo -TranscriptPath $nested
Check 'nested iterations counted once' ([int64]$info.ctx -eq 700783) "ctx=$($info.ctx)"

# A quota-error message ends a real transcript with an all-zero usage block.
$zeroLine = '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0},"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}'
[System.IO.File]::AppendAllText($nested, "`n" + $zeroLine, (New-Object System.Text.UTF8Encoding($false)))
$info = Get-ContextInfo -TranscriptPath $nested
Check 'zero-usage tail falls back to last real message' ([int64]$info.ctx -eq 700783) "ctx=$($info.ctx)"

# Bookkeeping lines at the end must not hide the last usage block.
$pad = ('{"type":"cost-state","sessionId":"x","totalCostUSD":1.0}' + "`n") * 4000
[System.IO.File]::AppendAllText($nested, $pad, (New-Object System.Text.UTF8Encoding($false)))
$info = Get-ContextInfo -TranscriptPath $nested
Check 'bookkeeping tail still finds the usage block' ([int64]$info.ctx -eq 700783) "ctx=$($info.ctx)"

# ---------- 3. signals ----------
Write-Host ''
Write-Host 'tool signals' -ForegroundColor Yellow

$sid = New-Sid
$f = (@{ session_id = $sid; cwd = $sandbox; hook_event_name = 'PostToolUseFailure'; tool_name = 'Bash'; tool_input = @{ command = 'npm test' }; error = 'Exit code 1' } | ConvertTo-Json -Compress)
Invoke-Hook 'post-tool.ps1' $f | Out-Null
$r = Invoke-Hook 'post-tool.ps1' $f
[void]$timings.Add([pscustomobject]@{ name = 'post-tool'; ms = $r.ms })
$st = Read-State $sid
Check 'two failures counted' ([int]$st['fails'] -eq 2) "fails=$($st['fails'])"

$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small 'the race condition is still failing, fix it')
Check 'repair loop routes to gear-max' ($r.text -match 'gear=max') $r.text

$sid2 = New-Sid
$e = (@{ session_id = $sid2; cwd = $sandbox; hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = @{ file_path = 'C:\x\a.ts' } } | ConvertTo-Json -Compress)
Invoke-Hook 'post-tool.ps1' $e | Out-Null
$st = Read-State $sid2
Check 'edited file recorded' (@($st['files']).Count -eq 1) "files=$(@($st['files']) -join ',')"

$ok = (@{ session_id = $sid2; cwd = $sandbox; hook_event_name = 'PostToolUse'; tool_name = 'Bash'; tool_input = @{ command = 'ls' } } | ConvertTo-Json -Compress)
Invoke-Hook 'post-tool.ps1' $ok | Out-Null
$st = Read-State $sid2
Check 'successful command clears the failure counter' ([int]$st['fails'] -eq 0) "fails=$($st['fails'])"

# On Windows the shell tool is 'PowerShell', not 'Bash'. If a successful call
# with that name doesn't clear the counter, the repair-loop signal latches on
# and every later turn gets told to spend gear-max.
$sid3 = New-Sid
$psFail = (@{ session_id = $sid3; cwd = $sandbox; hook_event_name = 'PostToolUseFailure'; tool_name = 'PowerShell'; tool_input = @{ command = 'npm test' }; error = 'Exit code 1' } | ConvertTo-Json -Compress)
Invoke-Hook 'post-tool.ps1' $psFail | Out-Null
$st = Read-State $sid3
$before = [int]$st['fails']
$psOk = (@{ session_id = $sid3; cwd = $sandbox; hook_event_name = 'PostToolUse'; tool_name = 'PowerShell'; tool_input = @{ command = 'git status' } } | ConvertTo-Json -Compress)
Invoke-Hook 'post-tool.ps1' $psOk | Out-Null
$st = Read-State $sid3
Check 'PowerShell tool failure counted' ($before -eq 1) "fails=$before"
Check 'successful PowerShell call clears the counter' ([int]$st['fails'] -eq 0) "fails=$($st['fails'])"

# This hook runs on every tool call, so a call that changes no signal must not
# rewrite the state file. A failed assertion here means needless disk churn on
# every Read and Grep.
$statePath = Get-StatePath $sid3
$mtBefore = (Get-Item -LiteralPath $statePath).LastWriteTimeUtc
Start-Sleep -Milliseconds 25
$readEvt = (@{ session_id = $sid3; cwd = $sandbox; hook_event_name = 'PostToolUse'; tool_name = 'Read'; tool_input = @{ file_path = 'C:\x\a.ts' } } | ConvertTo-Json -Compress)
Invoke-Hook 'post-tool.ps1' $readEvt | Out-Null
$mtAfter = (Get-Item -LiteralPath $statePath).LastWriteTimeUtc
Check 'a no-op tool call does not rewrite state' ($mtBefore -eq $mtAfter) "$mtBefore -> $mtAfter"

# The matcher in settings.json has to name every shell tool, or the hook above
# never receives the event at all.
$settingsPath = Join-Path $script:TunerRoot 'settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $matchers = @($settings.hooks.PostToolUse | ForEach-Object { [string]$_.matcher })
    $covered = ($matchers -join ',')
    Check 'PostToolUse matcher covers Bash and PowerShell' ($covered -match 'Bash' -and $covered -match 'PowerShell') $covered
}

# ---------- 4. stop: banners and the hard wrap ----------
Write-Host ''
Write-Host 'stop banner and hard wrap' -ForegroundColor Yellow

$sid = New-Sid
$r = Invoke-Hook 'stop.ps1' (New-Payload $sid $large '' 'default' 'Stop')
Check 'grace escalates instead of blocking' ($r.text -match 'escalated' -and $r.text -notmatch 'decision') $r.text

$sid = New-Sid
Invoke-Hook 'route.ps1' (New-Payload $sid $large 'carry on') | Out-Null
$r = Invoke-Hook 'stop.ps1' (New-Payload $sid $over '' 'default' 'Stop')
[void]$timings.Add([pscustomobject]@{ name = 'stop'; ms = $r.ms })
Check 'ceiling blocks the stop' ($r.text -match '"decision":"block"') $r.text
Check 'block reason names /wrap and /clear' ($r.text -match '/wrap' -and $r.text -match '/clear') $r.text

$r = Invoke-Hook 'stop.ps1' (New-Payload $sid $over '' 'default' 'Stop')
Check 'second stop is allowed, with the banner' ($r.text -notmatch '"decision"' -and $r.text -match 'systemMessage') $r.text

$sid = New-Sid
$r = Invoke-Hook 'stop.ps1' (New-Payload $sid $over '' 'default' 'Stop' $true)
Check 'stop_hook_active suppresses the block' ($r.text -notmatch '"decision"') $r.text

# Regression: when the prompt hook sees the ceiling first, it used to set the
# same flag the Stop hook uses for its banner, so the user never saw the banner.
$sid = New-Sid
Invoke-Hook 'route.ps1' (New-Payload $sid $over 'carry on') | Out-Null
Invoke-Hook 'stop.ps1' (New-Payload $sid $over '' 'default' 'Stop') | Out-Null
$r = Invoke-Hook 'stop.ps1' (New-Payload $sid $over '' 'default' 'Stop')
Check 'ceiling seen by the router still shows the stop banner' ($r.text -match 'systemMessage' -and $r.text -match '/wrap') $r.text

# A config with hardWrap off must fall back to the old banner-only behaviour.
$noHard = Join-Path $sandbox 'nohard.json'
# Fixtures come from the built-in defaults, never from a live install, so this
# suite runs identically on a developer machine and in CI.
$c = Get-TunerConfig -Defaults
$c.hardWrap = $false
$c | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $noHard -Encoding UTF8
$env:OPUS_TUNER_CONFIG = $noHard
$sid = New-Sid
$r = Invoke-Hook 'stop.ps1' (New-Payload $sid $over '' 'default' 'Stop')
$env:OPUS_TUNER_CONFIG = $script:BaseConfig
Check 'hardWrap off leaves only the banner' ($r.text -notmatch '"decision"' -and $r.text -match 'systemMessage') $r.text

$sid = New-Sid
$r = Invoke-Hook 'stop.ps1' (New-Payload $sid $small '' 'default' 'Stop')
Check 'stop below 70% stays silent' ($r.text.Length -eq 0) $r.text

# ---------- 5. compaction ----------
Write-Host ''
Write-Host 'compaction' -ForegroundColor Yellow

# Auto compaction is never blocked: if it is recovering from a context-limit
# error, blocking it surfaces that error and fails the request.
$sid = New-Sid
$r = Invoke-Hook 'pre-compact.ps1' (@{ session_id = $sid; cwd = $sandbox; transcript_path = $over; hook_event_name = 'PreCompact'; trigger = 'auto' } | ConvertTo-Json -Compress)
Check 'auto compaction is never blocked' ($r.text.Length -eq 0) $r.text

# Manual compaction is pure waste below the ceiling, so it is refused once.
$sid = New-Sid
$manual = (@{ session_id = $sid; cwd = $sandbox; transcript_path = $over; hook_event_name = 'PreCompact'; trigger = 'manual' } | ConvertTo-Json -Compress)
$r = Invoke-Hook 'pre-compact.ps1' $manual
Check 'first manual /compact is blocked' ($r.text -match '"decision":"block"') $r.text
Check 'compact reason names /wrap and /clear' ($r.text -match '/wrap' -and $r.text -match '/clear') $r.text

# A refusal is not a compaction. One row, action=compact-blocked: otherwise
# stats.ps1 would report refusals as the thing it is trying to count.
$logPath = Join-Path $env:OPUS_TUNER_STATE 'decisions.csv'
$mine = @(Import-Csv -LiteralPath $logPath | Where-Object { $_.session -eq $sid.Substring(0, 8) })
Check 'blocked /compact logs one blocked row' (@($mine | Where-Object { $_.action -eq 'compact-blocked' }).Count -eq 1 -and @($mine | Where-Object { $_.action -eq 'compact-manual' }).Count -eq 0) (@($mine.action) -join ',')

$r = Invoke-Hook 'pre-compact.ps1' $manual
Check 'second manual /compact is allowed' ($r.text.Length -eq 0) $r.text

$noBlock = Join-Path $sandbox 'noblock.json'
$c = Get-TunerConfig -Defaults
$c.blockManualCompact = $false
$c | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $noBlock -Encoding UTF8
$env:OPUS_TUNER_CONFIG = $noBlock
$sid = New-Sid
$r = Invoke-Hook 'pre-compact.ps1' (@{ session_id = $sid; cwd = $sandbox; transcript_path = $over; hook_event_name = 'PreCompact'; trigger = 'manual' } | ConvertTo-Json -Compress)
$env:OPUS_TUNER_CONFIG = $script:BaseConfig
Check 'blockManualCompact off only logs' ($r.text.Length -eq 0) $r.text

# ---------- 6. enforcement ----------
Write-Host ''
Write-Host 'enforcement (mode=advise)' -ForegroundColor Yellow

$sid = New-Sid
$read = (@{ session_id = $sid; cwd = $sandbox; transcript_path = $large; hook_event_name = 'PreToolUse'; tool_name = 'Read'; tool_input = @{ file_path = 'C:\big.ts' } } | ConvertTo-Json -Compress)
$r = Invoke-Hook 'pre-tool.ps1' $read
Check 'advise mode never blocks a read' ($r.text.Length -eq 0) $r.text

# ---------- 6. handoff ----------
Write-Host ''
Write-Host 'handoff round trip' -ForegroundColor Yellow

$briefOut = (& $Interpreter @ExePrefix -File (Join-Path $here 'brief.ps1') -Cwd $sandbox -Transcript $large) -join "`n"
$briefPath = Join-Path (Join-Path $sandbox '.claude') 'handoff.md'
Check 'brief.ps1 writes .claude/handoff.md' (Test-Path $briefPath) $briefOut
if (Test-Path $briefPath) {
    $t = Get-Content $briefPath -Raw
    Check 'brief has all required sections' (
        $t -match '## Decisions' -and $t -match '## Dead ends' -and
        $t -match '## Unverified assumptions' -and $t -match '## Next step')
}

$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'clear'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'clear re-seeds from the brief' ($r.text -match 'Resuming from a handoff') $r.text.Substring(0, [Math]::Min(120, $r.text.Length))
Check 'brief consumed after re-seed' (-not (Test-Path $briefPath) -and (Test-Path (Join-Path (Join-Path $sandbox '.claude') 'handoff.consumed.md')))

# The VS Code panel often starts a new conversation as 'startup', not 'clear'.
Set-Content -LiteralPath $briefPath -Value "# Handoff`n`n## Next step`n`nrun the tests" -Encoding UTF8
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'fresh startup re-seeds (VS Code new chat)' ($r.text -match 'Resuming from a handoff') $r.text
Check 'startup consumes the brief' (-not (Test-Path $briefPath))

Set-Content -LiteralPath $briefPath -Value "# Handoff`n`n## Next step`n`nstale work" -Encoding UTF8
(Get-Item -LiteralPath $briefPath).LastWriteTime = (Get-Date).AddDays(-3)
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'stale startup brief is ignored' ($r.text.Length -eq 0 -and (Test-Path $briefPath)) $r.text
Remove-Item -LiteralPath $briefPath -Force

Set-Content -LiteralPath $briefPath -Value "# Handoff`n`n## Next step`n`nresume work" -Encoding UTF8
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'resume'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'resume does not inject the brief' ($r.text.Length -eq 0)
Remove-Item -LiteralPath $briefPath -Force

# Resuming pays before the first new token. The warning must ride on
# systemMessage (free) rather than additionalContext (billed on every turn).
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'resume'; transcript_path = $over; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'resume warns about the context cost' ($r.text -match 'resuming at 260k') $r.text
Check 'resume warning costs no context' ($r.text -match 'systemMessage' -and $r.text -notmatch 'additionalContext') $r.text

# A malformed config falls back to defaults. Silence would make a typo invisible.
$badCfg = Join-Path $sandbox 'bad.json'
Set-Content -LiteralPath $badCfg -Value '{ "routineTokens": 150000,' -Encoding UTF8
$env:OPUS_TUNER_CONFIG = $badCfg
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
$env:OPUS_TUNER_CONFIG = $script:BaseConfig
Check 'malformed config is reported' ($r.text -match 'not valid JSON') $r.text

$sid = New-Sid
Set-Content -LiteralPath (Get-StatePath $sid) -Value '{"tier":"deep","gear":"high","files":[],"fails":0,"maxUses":0,"nudged":{"soft":false,"ceiling":false,"escalated":false}}' -Encoding UTF8
Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'resume'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress) | Out-Null
Check 'resume keeps the deep tier' ((Read-State $sid)['tier'] -eq 'deep')

$sid = New-Sid
Set-Content -LiteralPath (Get-StatePath $sid) -Value '{"tier":"deep","gear":"high","files":[],"fails":0,"maxUses":0,"nudged":{"soft":false,"ceiling":false,"escalated":false}}' -Encoding UTF8
Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress) | Out-Null
Check 'startup resets to routine' ((Read-State $sid)['tier'] -eq 'routine')

# mode: off is documented as silencing everything; the brief re-seed is part of
# the bundle, so it must be silent too - otherwise "off" still spends tokens.
$offCfg = Join-Path $sandbox 'off.json'
# Fixtures come from the built-in defaults, never from a live install, so this
# suite runs identically on a developer machine and in CI.
$c = Get-TunerConfig -Defaults
$c.mode = 'off'
$c | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $offCfg -Encoding UTF8
Set-Content -LiteralPath $briefPath -Value "# Handoff`n`n## Next step`n`nshould not load" -Encoding UTF8
$env:OPUS_TUNER_CONFIG = $offCfg
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'clear'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
$env:OPUS_TUNER_CONFIG = $script:BaseConfig
Check 'mode off silences session start' ($r.text.Length -eq 0 -and (Test-Path $briefPath)) $r.text
Remove-Item -LiteralPath $briefPath -Force -ErrorAction SilentlyContinue

# Regression: a compaction resets the session, and used to re-arm the
# once-per-session limits along with it.
$sid = New-Sid
Set-Content -LiteralPath (Get-StatePath $sid) -Value '{"tier":"deep","gear":"high","files":[],"fails":3,"maxUses":2,"nudged":{"soft":true,"ceiling":true,"escalated":true,"hardWrap":true,"compact":true}}' -Encoding UTF8
Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'compact'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress) | Out-Null
$st = Read-State $sid
Check 'compaction resets the tier and counters' ($st['tier'] -eq 'routine' -and [int]$st['fails'] -eq 0 -and -not [bool]$st['nudged']['hardWrap']) ($st | ConvertTo-Json -Compress -Depth 4)
Check 'compaction keeps the once-per-session limits' ([bool]$st['nudged']['compact'] -and [int]$st['maxUses'] -eq 2) ($st | ConvertTo-Json -Compress -Depth 4)

# Regression: mode off must not write state from the tool hook either.
$env:OPUS_TUNER_CONFIG = $offCfg
$sid = New-Sid
Invoke-Hook 'post-tool.ps1' (@{ session_id = $sid; cwd = $sandbox; hook_event_name = 'PostToolUseFailure'; tool_name = 'Bash'; tool_input = @{ command = 'x' }; error = 'Exit code 1' } | ConvertTo-Json -Compress) | Out-Null
$env:OPUS_TUNER_CONFIG = $script:BaseConfig
Check 'mode off writes no state from tool calls' (-not (Test-Path -LiteralPath (Get-StatePath $sid)))

# ---------- profiles ----------
Write-Host ''
Write-Host 'profiles' -ForegroundColor Yellow

function Invoke-Profile {
    param([string[]]$Arguments = @())
    $o = & $Interpreter @ExePrefix -File (Join-Path $here 'profile.ps1') @Arguments 2>&1
    return (($o | Where-Object { $_ -is [string] }) -join "`n")
}

$out = Invoke-Profile @('show')
Check 'default profile is dev and adds nothing' ($out -match 'profile: dev' -and $out -match 'adds nothing') $out

# A config with other settings in it: the switch must change one key only.
$profCfg = Join-Path $sandbox 'profile.json'
[System.IO.File]::WriteAllText($profCfg, "{`n  `"routineTokens`": 140000,`n  `"mode`": `"advise`"`n}`n", (New-Object System.Text.UTF8Encoding($false)))
$env:OPUS_TUNER_CONFIG = $profCfg

$out = Invoke-Profile
$saved = Get-Content -LiteralPath $profCfg -Raw | ConvertFrom-Json
Check 'bare /profile swaps dev to creative' ($out -match 'Switched from dev to creative' -and $saved.profile -eq 'creative') $out
Check 'the switch keeps the other settings' ([int]$saved.routineTokens -eq 140000 -and $saved.mode -eq 'advise') (Get-Content -LiteralPath $profCfg -Raw)
Check 'the switch prints the instruction it adds' ($out -match 'profile=creative') $out

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $mid 'rename all the variables in the codebase')
Check 'creative never downshifts to gear-low' ($r.text -notmatch 'gear=low') $r.text

$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small 'outline chapter three with a darker story arc')
Check 'creative escalates on long-form work' ($r.text -match 'tier=deep') $r.text

$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'creative note is added at session start' ($r.text -match 'additionalContext' -and $r.text -match 'profile=creative') $r.text
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'resume'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'resume does not repeat the note' ($r.text -notmatch 'profile=creative') $r.text

$slCreative = (@{ session_id = $sid; cwd = $sandbox; context_window = @{ total_input_tokens = 50000 } } | ConvertTo-Json -Compress -Depth 4)
$r = Invoke-Hook 'statusline.ps1' $slCreative
Check 'status line shows a non-dev profile' ($r.text -match 'creative') $r.text

$out = Invoke-Profile @('dev')
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check '/profile dev switches back and goes quiet' ($out -match 'Switched from creative to dev' -and $r.text.Length -eq 0) "$out | $($r.text)"

$out = Invoke-Profile @('poetry')
Check 'unknown profile name is refused' ($out -match 'Unknown profile') $out

$badProf = Join-Path $sandbox 'badprofile.json'
Set-Content -LiteralPath $badProf -Value '{ "profile": "creatve" }' -Encoding UTF8
$env:OPUS_TUNER_CONFIG = $badProf
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'a misspelt profile is reported, not silently ignored' ($r.text -match 'unknown profile' -and $r.text -notmatch 'additionalContext') $r.text
$env:OPUS_TUNER_CONFIG = $script:BaseConfig

# ---------- automatic savings ----------
Write-Host ''
Write-Host 'automatic savings' -ForegroundColor Yellow

# Weak words alone must not unlock the 250k tier for the rest of the session.
$sid = New-Sid
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small 'why is this function slow')
Check 'everyday "why is" question stays routine' ($r.text -notmatch 'tier=deep') $r.text

$sid = New-Sid
Set-Content -LiteralPath (Get-StatePath $sid) -Value '{"tier":"routine","gear":"high","files":[],"fails":1,"maxUses":0,"nudged":{}}' -Encoding UTF8
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small 'why is the build still failing')
Check 'weak words plus a failure escalate' ($r.text -match 'tier=deep') $r.text

$sid = New-Sid
$longAsk = 'why does the checkout page time out for some users? ' + ('It started after the last deploy and only happens on large carts with many line items. ' * 5)
$r = Invoke-Hook 'route.ps1' (New-Payload $sid $small $longAsk)
Check 'weak words in a long, detailed prompt escalate' ($r.text -match 'tier=deep') $r.text

# The at-ceiling note goes out once per crossing, not on every prompt.
$sid = New-Sid
$first = Invoke-Hook 'route.ps1' (New-Payload $sid $over 'carry on')
$second = Invoke-Hook 'route.ps1' (New-Payload $sid $over 'and the next thing')
Check 'ceiling note is said once, not every prompt' ($first.text -match 'ceiling' -and $second.text.Length -eq 0) "first=[$($first.text)] second=[$($second.text)]"

# One oversized tool result gets a single short note; small ones and edits do not.
function New-ToolEvent {
    param([string]$Sid, [string]$Tool, $Response)
    return (@{ session_id = $Sid; cwd = $sandbox; hook_event_name = 'PostToolUse'; tool_name = $Tool; tool_input = @{ command = 'x' }; tool_response = $Response } | ConvertTo-Json -Compress -Depth 6)
}
$sid = New-Sid
$big = @{ stdout = ('x' * 40000); stderr = ''; interrupted = $false }
$r = Invoke-Hook 'post-tool.ps1' (New-ToolEvent $sid 'Bash' $big)
Check 'a ~10k-token Bash result gets a note' ($r.text -match 'additionalContext' -and $r.text -match '~10k tokens' -and $r.text -match 'tail') $r.text
$r = Invoke-Hook 'post-tool.ps1' (New-ToolEvent $sid 'Read' @{ type = 'text'; file = @{ filePath = 'a.ts'; content = 'short' } })
Check 'a small result gets no note' ($r.text.Length -eq 0) $r.text
$r = Invoke-Hook 'post-tool.ps1' (New-ToolEvent $sid 'Edit' @{ filePath = 'a.ts'; originalFile = ('y' * 60000) })
Check 'an edit echoing a big file gets no note' ($r.text.Length -eq 0) $r.text
Invoke-Hook 'post-tool.ps1' (New-ToolEvent $sid 'Bash' $big) | Out-Null
Invoke-Hook 'post-tool.ps1' (New-ToolEvent $sid 'Bash' $big) | Out-Null
$r = Invoke-Hook 'post-tool.ps1' (New-ToolEvent $sid 'Bash' $big)
Check 'notes stop after the per-session cap' ($r.text.Length -eq 0 -and [int](Read-State $sid)['bigWarned'] -eq 3) $r.text

# The weekly digest: once, as a zero-token systemMessage, then not for 7 days.
Remove-Item -LiteralPath (Join-Path $env:OPUS_TUNER_STATE 'digest.stamp') -Force
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'weekly digest shows on a fresh start' ($r.text -match 'last 7 days' -and $r.text -match 'gear switch' -and $r.text -match 'systemMessage' -and $r.text -notmatch 'additionalContext') $r.text
$sid = New-Sid
$r = Invoke-Hook 'session-start.ps1' (@{ session_id = $sid; cwd = $sandbox; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress)
Check 'weekly digest does not repeat within the week' ($r.text -notmatch 'last 7 days') $r.text

# ---------- 7. status line ----------
Write-Host ''
Write-Host 'status line' -ForegroundColor Yellow

$sid = New-Sid
$sl = (@{
    session_id     = $sid
    cwd            = $sandbox
    model          = @{ display_name = 'Opus 5.5' }
    context_window = @{ total_input_tokens = 92000 }
    effort         = @{ level = 'high' }
    rate_limits    = @{ five_hour = @{ used_percentage = 41 }; seven_day = @{ used_percentage = 12 } }
} | ConvertTo-Json -Compress -Depth 5)
$r = Invoke-Hook 'statusline.ps1' $sl
[void]$timings.Add([pscustomobject]@{ name = 'statusline'; ms = $r.ms })
Check 'status line renders context vs ceiling' ($r.text -match '/150k') $r.text
Check 'status line shows the 5h window' ($r.text -match '5h 41%') $r.text

# ---------- 8. decision log ----------
Write-Host ''
Write-Host 'decision log' -ForegroundColor Yellow

$logPath = Join-Path $env:OPUS_TUNER_STATE 'decisions.csv'
Check 'decisions.csv written' (Test-Path -LiteralPath $logPath) $logPath
if (Test-Path -LiteralPath $logPath) {
    $logRows = @(Import-Csv -LiteralPath $logPath)
    $gears = @($logRows | Where-Object { $_.action -like 'gear-*' }).Count
    $escs = @($logRows | Where-Object { $_.action -like 'escalate-*' }).Count
    $wraps = @($logRows | Where-Object { $_.action -eq 'hard-wrap' }).Count
    Check 'gears, escalations and hard wraps all logged' ($gears -gt 0 -and $escs -gt 0 -and $wraps -gt 0) "gear=$gears escalate=$escs hardwrap=$wraps"
    $compacts = @($logRows | Where-Object { $_.action -like 'compact-*' }).Count
    Check 'compaction events logged' ($compacts -ge 3) "rows=$compacts"
}

$stats = & $Interpreter @ExePrefix -File (Join-Path $here 'stats.ps1') -All 2>&1
$statsText = ($stats | Where-Object { $_ -is [string] }) -join "`n"
Check 'stats.ps1 summarizes the log' ($statsText -match 'by action' -and $statsText -match 'hard-wrap') $statsText.Substring(0, [Math]::Min(200, $statsText.Length))

# ---------- 9. audit comparison ----------
Write-Host ''
Write-Host 'audit baseline comparison' -ForegroundColor Yellow

# audit.ps1 reads <config>/projects, so give it a sandbox transcript of its own
# rather than pointing at whatever the developer has been working on.
$proj = Join-Path (Join-Path $sandbox 'projects') 'p1'
New-Item -ItemType Directory -Force -Path $proj | Out-Null
$u = '{"type":"assistant","message":{"model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":120000,"cache_creation_input_tokens":0,"output_tokens":300}}}'
$pad = ('{"type":"cost-state","sessionId":"x","totalCostUSD":0.1}' + "`n") * 300
[System.IO.File]::WriteAllText((Join-Path $proj 's1.jsonl'), $u + "`n" + $pad, (New-Object System.Text.UTF8Encoding($false)))

$baseCsv = Join-Path $sandbox 'baseline.csv'
@(
    'Session,MB,Requests,CacheReadM,CacheWrM,OutputK,PeakCtxK,Model,CostUSD,LastWrite',
    'aaaaaaaa,10,100,500,10,20,300,opus,900,01-01',
    'bbbbbbbb,10,100,500,10,20,320,opus,900,01-02'
) | Set-Content -LiteralPath $baseCsv -Encoding UTF8

$oldCfgDir = $env:CLAUDE_CONFIG_DIR
$env:CLAUDE_CONFIG_DIR = $sandbox
$auditOut = (& $Interpreter @ExePrefix -File (Join-Path $here 'audit.ps1') -Recent 0 -Baseline $baseCsv) -join "`n"
$env:CLAUDE_CONFIG_DIR = $oldCfgDir

Check 'audit prints a baseline comparison' ($auditOut -match 'baseline comparison') $auditOut
Check 'comparison includes a delta' ($auditOut -match 'cache read' -and $auditOut -match '-?\d+%') $auditOut

# ---------- 10. timing ----------
Write-Host ''
Write-Host 'timing (UserPromptSubmit and Stop block the session; PostToolUse is async)' -ForegroundColor Yellow
$budget = $BudgetMs
$worst = ($timings | Measure-Object -Property ms -Maximum).Maximum
# Charge the interpreter start to the platform, not to the hook. The gate is
# "someone made the hook slower", and a shared runner's cold start is noise that
# otherwise fails the build at 3120 ms against a 3000 ms budget.
$overhead = [Math]::Max(0, $worst - $BaselineMs)
foreach ($t in $timings) {
    $own = [Math]::Max(0, $t.ms - $BaselineMs)
    $flag = if ($own -gt $budget) { 'SLOW' } else { 'ok' }
    Write-Host ("  {0,-12} {1,4} ms  ({2,4} ms own)  {3}" -f $t.name, $t.ms, $own, $flag)
}
Write-Host ("  interpreter start: {0} ms" -f $BaselineMs) -ForegroundColor DarkGray
# Floor on Windows PowerShell 5.1: ~150 ms to spawn the process, ~50 ms to parse
# this bundle, ~90 ms for the first ConvertFrom-Json (assembly load), ~100 ms for
# the first transcript read and regex use. The scripts' own work is ~20 ms warm.
# pwsh 7 measured slower on the development machine - see the README before
# "fixing" that, and re-measure on your own hardware.
Check "every hook under $budget ms above a ${BaselineMs}ms start" ($overhead -lt $budget) "worst=${worst}ms, own=${overhead}ms"

# ---------- cleanup ----------
foreach ($s in $createdStates) {
    $p = Get-StatePath $s
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
# Belt and braces: anything the run created but did not track (a script that
# failed before recording its id) would otherwise linger as a fake session.
Get-ChildItem -LiteralPath $script:TunerState -Filter 'st-*.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $startedAt } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) {
    Write-Host "$pass passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$pass passed, $fail failed" -ForegroundColor Red
    exit 1
}
