# Overlapping hooks must not reverse a tier, lose a control flag, or fire a
# one-time interruption twice, and a damaged state file must not re-arm one.
#
# The overlaps are deterministic, not stress runs: OPUS_TUNER_TEST_BARRIER holds a
# hook between its read and its write, and the second hook starts only once the
# first is parked there.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/state-test.ps1
#   pwsh -NoProfile -File tests/state-test.ps1

param([string]$Interpreter = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Interpreter = Get-TestInterpreter $Interpreter
$null = New-TestSandbox 'state'

$proj = Join-Path $script:Sandbox 'project'
New-Item -ItemType Directory -Force -Path $proj | Out-Null
Set-TestConfig '{"mode":"guard","hardWrap":true,"blockManualCompact":true,"maxTurnsPerSession":1}'

Write-Host "state tests  (interpreter: $($script:Interpreter))" -ForegroundColor Cyan

# The decision log keeps the first eight characters, so those have to differ.
function New-Sid { return [guid]::NewGuid().ToString('N').Substring(0, 12) + '-state' }

function Get-ControlPath { param([string]$Sid) return (Join-Path $script:StateDir "$Sid.json") }
function Get-DiagPath { param([string]$Sid) return (Join-Path $script:StateDir "$Sid.diag.json") }

function Read-RawJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return $null }
}

function Write-Raw {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-BarrierPrefix {
    return (Join-Path $script:Sandbox ('barrier-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
}

# A hook that parks at its barrier until the test releases it.
function Start-Held {
    param([string]$Script, [string]$Payload, [string]$Prefix)
    $env:OPUS_TUNER_TEST_BARRIER = $Prefix
    try { return (Start-ScriptProcess $Script @() $Payload) }
    finally { Remove-Item Env:OPUS_TUNER_TEST_BARRIER -ErrorAction SilentlyContinue }
}

# A hook that never parks but reports when it finds the lock taken.
function Start-Contender {
    param([string]$Script, [string]$Payload, [string]$Prefix)
    Write-Raw "$Prefix.go" ''
    return (Start-Held $Script $Payload $Prefix)
}

function Wait-ForFile {
    param([string]$Path, [int]$TimeoutMs = 20000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path -LiteralPath $Path) { return $true }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

function Test-Blocked { param([string]$Text) return ($Text -match '"decision"\s*:\s*"block"') }

function Get-StopPayload {
    param([string]$Sid, [string]$Transcript)
    return (@{ session_id = $Sid; cwd = $proj; hook_event_name = 'Stop'; stop_hook_active = $false; transcript_path = $Transcript } | ConvertTo-Json -Compress)
}

function Get-RoutePayload {
    param([string]$Sid, [string]$Transcript, [string]$Prompt)
    return (@{ session_id = $Sid; cwd = $proj; hook_event_name = 'UserPromptSubmit'; prompt = $Prompt; transcript_path = $Transcript } | ConvertTo-Json -Compress)
}

function Get-CompactPayload {
    param([string]$Sid, [string]$Transcript)
    return (@{ session_id = $Sid; cwd = $proj; hook_event_name = 'PreCompact'; trigger = 'manual'; transcript_path = $Transcript } | ConvertTo-Json -Compress)
}

function Get-FailurePayload {
    param([string]$Sid)
    return (@{ session_id = $Sid; cwd = $proj; hook_event_name = 'PostToolUseFailure'; tool_name = 'Bash'; tool_input = @{ command = 'x' }; error = 'Exit code 1' } | ConvertTo-Json -Compress)
}

function Get-RecoveredRows {
    param([string]$Sid)
    $log = Join-Path $script:StateDir 'decisions.csv'
    if (-not (Test-Path -LiteralPath $log)) { return 0 }
    $short = $Sid.Substring(0, 8)
    return @([System.IO.File]::ReadAllLines($log) | Where-Object { $_ -match ",$short," -and $_ -match ',state-recovered' }).Count
}

# ---------- a tool hook against a control update ----------
Write-Section 'a stale tool hook cannot touch control state'

$sid = New-Sid
# 160k sits in the grace band of the routine ceiling, so Stop escalates the tier.
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 160000
$a = New-BarrierPrefix
$heldA = Start-Held 'post-tool.ps1' (Get-FailurePayload $sid) $a
Check 'the tool hook parks between its read and its write' (Wait-ForFile "$a.reached")
$r = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
$control = Read-RawJson (Get-ControlPath $sid)
Check 'a control update does not wait for a tool hook' ($r.code -eq 0 -and $control -and $control.tier -eq 'deep') "exit $($r.code): $($r.text)"
Write-Raw "$a.go" ''
$null = Wait-ScriptProcess $heldA
$control = Read-RawJson (Get-ControlPath $sid)
$diag = Read-RawJson (Get-DiagPath $sid)
Check 'the escalation survives the stale tool hook' ($control -and $control.tier -eq 'deep') ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the escalation flag survives too' ($control -and $control.nudged.escalated -eq $true) ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the tool hook still counted its failure' ($diag -and [int]$diag.fails -eq 1) ($diag | ConvertTo-Json -Compress -Depth 4)

# ---------- two control updates ----------
Write-Section 'overlapping control updates keep both results'

$sid = New-Sid
# 200k is past the routine ceiling and its grace band.
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
$a = New-BarrierPrefix
$b = New-BarrierPrefix
$heldA = Start-Held 'route.ps1' (Get-RoutePayload $sid $tr 'what is next') $a
Check 'the first hook parks holding the lock' (Wait-ForFile "$a.reached")
$heldB = Start-Contender 'stop.ps1' (Get-StopPayload $sid $tr) $b
Check 'the second hook finds the lock taken' (Wait-ForFile "$b.waiting")
Write-Raw "$a.go" ''
$null = Wait-ScriptProcess $heldA
$resB = Wait-ScriptProcess $heldB
$control = Read-RawJson (Get-ControlPath $sid)
Check 'the first flag is kept' ($control -and $control.nudged.routeCeiling -eq $true) ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the second flag is kept' ($control -and $control.nudged.hardWrap -eq $true) ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the stop that held no lock still blocks' (Test-Blocked $resB.text) $resB.text
$r = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
Check 'the next stop is allowed' (-not (Test-Blocked $r.text)) $r.text

# The reverse order is the one that used to lose the tier: the writer holding the
# older copy of the state finishes last.
$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 160000
Write-Raw (Get-ControlPath $sid) '{"tier":"routine","gear":"low","maxUses":0,"nudged":{}}'
$a = New-BarrierPrefix
$b = New-BarrierPrefix
$heldA = Start-Held 'stop.ps1' (Get-StopPayload $sid $tr) $a
Check 'the escalating stop parks' (Wait-ForFile "$a.reached")
$heldB = Start-Contender 'route.ps1' (Get-RoutePayload $sid $tr 'what is next') $b
Check 'the routing hook finds the lock taken' (Wait-ForFile "$b.waiting")
Write-Raw "$a.go" ''
$null = Wait-ScriptProcess $heldA
$null = Wait-ScriptProcess $heldB
$control = Read-RawJson (Get-ControlPath $sid)
Check 'a tier escalation cannot be reversed' ($control -and $control.tier -eq 'deep') ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the routing hook applied its own change on top' ($control -and $control.gear -eq 'high') ($control | ConvertTo-Json -Compress -Depth 4)

# ---------- one-time interruptions ----------
Write-Section 'a one-time interruption fires once'

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
$a = New-BarrierPrefix
$b = New-BarrierPrefix
$heldA = Start-Held 'stop.ps1' (Get-StopPayload $sid $tr) $a
Check 'the first stop parks before writing its flag' (Wait-ForFile "$a.reached")
$heldB = Start-Contender 'stop.ps1' (Get-StopPayload $sid $tr) $b
Check 'the second stop finds the lock taken' (Wait-ForFile "$b.waiting")
Write-Raw "$a.go" ''
$resA = Wait-ScriptProcess $heldA
$resB = Wait-ScriptProcess $heldB
$blocks = @(@($resA, $resB) | Where-Object { Test-Blocked $_.text }).Count
Check 'overlapping stops block exactly once' ($blocks -eq 1) "blocks=$blocks; A=$($resA.text); B=$($resB.text)"

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
$a = New-BarrierPrefix
$b = New-BarrierPrefix
$heldA = Start-Held 'pre-compact.ps1' (Get-CompactPayload $sid $tr) $a
Check 'the first /compact parks before writing its flag' (Wait-ForFile "$a.reached")
$heldB = Start-Contender 'pre-compact.ps1' (Get-CompactPayload $sid $tr) $b
Check 'the second /compact finds the lock taken' (Wait-ForFile "$b.waiting")
Write-Raw "$a.go" ''
$resA = Wait-ScriptProcess $heldA
$resB = Wait-ScriptProcess $heldB
$blocks = @(@($resA, $resB) | Where-Object { Test-Blocked $_.text }).Count
Check 'overlapping manual compactions block exactly once' ($blocks -eq 1) "blocks=$blocks; A=$($resA.text); B=$($resB.text)"

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
$racers = @(1..4 | ForEach-Object { Start-ScriptProcess 'stop.ps1' @() (Get-StopPayload $sid $tr) })
$results = @($racers | ForEach-Object { Wait-ScriptProcess $_ })
$blocks = @($results | Where-Object { Test-Blocked $_.text }).Count
Check 'four racing stops block exactly once' ($blocks -eq 1) "blocks=$blocks"

# ---------- effort limits ----------
Write-Section 'an effort limit is spent once'

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 80000
Write-Raw (Get-ControlPath $sid) '{"tier":"routine","gear":"high","maxUses":0,"nudged":{}}'
Write-Raw (Get-DiagPath $sid) '{"fails":2,"files":[],"bigWarned":0,"lowFailed":false}'
$a = New-BarrierPrefix
$b = New-BarrierPrefix
$prompt = 'the race condition is still failing, fix it'
$heldA = Start-Held 'route.ps1' (Get-RoutePayload $sid $tr $prompt) $a
Check 'the first request parks before counting its use' (Wait-ForFile "$a.reached")
$heldB = Start-Contender 'route.ps1' (Get-RoutePayload $sid $tr $prompt) $b
Check 'the second request finds the lock taken' (Wait-ForFile "$b.waiting")
Write-Raw "$a.go" ''
$resA = Wait-ScriptProcess $heldA
$resB = Wait-ScriptProcess $heldB
$maxes = @(@($resA, $resB) | Where-Object { $_.text -match 'gear=max' }).Count
$control = Read-RawJson (Get-ControlPath $sid)
Check 'two requests cannot both spend the last gear-max' ($maxes -eq 1) "A=$($resA.text); B=$($resB.text)"
Check 'the use is counted once' ($control -and [int]$control.maxUses -eq 1) ($control | ConvertTo-Json -Compress -Depth 4)

# ---------- control and diagnostics ----------
Write-Section 'control state and diagnostics are separate'

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
$null = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
$before = if (Test-Path -LiteralPath (Get-ControlPath $sid)) { [System.IO.File]::ReadAllText((Get-ControlPath $sid)) } else { '' }
$null = Invoke-Script 'post-tool.ps1' @() (Get-FailurePayload $sid)
$editPayload = @{ session_id = $sid; cwd = $proj; hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = @{ file_path = (Join-Path $proj 'a.ts') } } | ConvertTo-Json -Compress
$null = Invoke-Script 'post-tool.ps1' @() $editPayload
$after = if (Test-Path -LiteralPath (Get-ControlPath $sid)) { [System.IO.File]::ReadAllText((Get-ControlPath $sid)) } else { '' }
$control = Read-RawJson (Get-ControlPath $sid)
$diag = Read-RawJson (Get-DiagPath $sid)
Check 'tool hooks never rewrite the control file' ($before -and $before -ceq $after) "$before -> $after"
Check 'the control file holds no counters' ($control -and $null -eq $control.fails -and $null -eq $control.files -and $null -eq $control.bigWarned) ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the diagnostics file holds the counters' ($diag -and @($diag.files).Count -eq 1 -and $null -eq $diag.tier -and $null -eq $diag.nudged) ($diag | ConvertTo-Json -Compress -Depth 4)

# A session that spans the upgrade still has one flat file.
$sid = New-Sid
Write-Raw (Get-ControlPath $sid) '{"tier":"deep","gear":"high","files":["a.ts"],"fails":2,"maxUses":1,"bigWarned":1,"lowFailed":false,"nudged":{"hardWrap":true}}'
$null = Invoke-Script 'post-tool.ps1' @() (Get-FailurePayload $sid)
$control = Read-RawJson (Get-ControlPath $sid)
$diag = Read-RawJson (Get-DiagPath $sid)
Check 'a flat state file keeps its counters' ($diag -and [int]$diag.fails -eq 3 -and @($diag.files).Count -eq 1) ($diag | ConvertTo-Json -Compress -Depth 4)
Check 'a flat state file keeps its control state' ($control -and $control.tier -eq 'deep' -and $control.nudged.hardWrap -eq $true) ($control | ConvertTo-Json -Compress -Depth 4)

$sid = New-Sid
$racers = @(1..6 | ForEach-Object { Start-ScriptProcess 'post-tool.ps1' @() (Get-FailurePayload $sid) })
$null = @($racers | ForEach-Object { Wait-ScriptProcess $_ })
$diag = Read-RawJson (Get-DiagPath $sid)
Check 'parallel tool hooks lose no counter' ($diag -and [int]$diag.fails -eq 6) ($diag | ConvertTo-Json -Compress -Depth 4)

# ---------- interrupted writes ----------
Write-Section 'interrupted writes change nothing'

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
$intact = '{"tier":"routine","gear":"high","maxUses":0,"nudged":{"routeCeiling":true}}'
Write-Raw (Get-ControlPath $sid) $intact
$a = New-BarrierPrefix
$heldA = Start-Held 'stop.ps1' (Get-StopPayload $sid $tr) $a
Check 'the writer parks before writing' (Wait-ForFile "$a.reached")
if ($heldA.process -and -not $heldA.process.HasExited) { $heldA.process.Kill() }
[void]$heldA.process.WaitForExit(10000)
Check 'a killed writer leaves the state as it was' ([System.IO.File]::ReadAllText((Get-ControlPath $sid)) -ceq $intact)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
$control = Read-RawJson (Get-ControlPath $sid)
Check 'its lock died with it' ($control -and $control.nudged.hardWrap -eq $true) "after $($sw.ElapsedMilliseconds) ms: $($r.text)"
Check 'the next hook still takes its one interruption' (Test-Blocked $r.text) $r.text

# Half a temp file from a crash between writing and swapping.
$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
Write-Raw (Get-ControlPath $sid) '{"tier":"routine","gear":"high","maxUses":0,"nudged":{"hardWrap":true,"routeCeiling":true}}'
Write-Raw "$(Get-ControlPath $sid).999.deadbeef.tmp" '{"tier":"routine","nudged":{"hardWr'
$r = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
Check 'a leftover temp file is ignored' (-not (Test-Blocked $r.text)) $r.text
$control = Read-RawJson (Get-ControlPath $sid)
Check 'the real file stays authoritative' ($control -and $control.nudged.hardWrap -eq $true) ($control | ConvertTo-Json -Compress -Depth 4)
Remove-Item -LiteralPath "$(Get-ControlPath $sid).999.deadbeef.tmp" -Force
$leftovers = @(Get-ChildItem -LiteralPath $script:StateDir -Filter '*.tmp' -File)
Check 'no update leaves a temp file behind' ($leftovers.Count -eq 0) (@($leftovers.Name) -join ',')

$oldTmp = Join-Path $script:StateDir 'crashed.json.1.aaaa.tmp'
$newTmp = Join-Path $script:StateDir 'crashed.json.2.bbbb.tmp'
Write-Raw $oldTmp 'x'
Write-Raw $newTmp 'x'
(Get-Item -LiteralPath $oldTmp).LastWriteTime = (Get-Date).AddDays(-2)
$startPayload = @{ session_id = (New-Sid); cwd = $proj; hook_event_name = 'SessionStart'; source = 'startup' } | ConvertTo-Json -Compress
$null = Invoke-Script 'session-start.ps1' @() $startPayload
Check 'a fresh start clears old temp files' (-not (Test-Path -LiteralPath $oldTmp))
Check 'a recent temp file may belong to a running hook' (Test-Path -LiteralPath $newTmp)
Remove-Item -LiteralPath $newTmp -Force

# ---------- malformed state ----------
Write-Section 'malformed state does not re-arm an interruption'

$damaged = [ordered]@{
    'truncated JSON'       = '{"tier":"deep","nudged":{"hardWrap":tr'
    'an empty file'        = ''
    'a JSON array'         = '[1,2,3]'
    'a broken flag object' = '{"tier":"routine","gear":"high","maxUses":0,"nudged":"damaged"}'
    'a limit of the wrong type' = '{"tier":"routine","gear":"high","maxUses":"many","nudged":{}}'
}
foreach ($kind in $damaged.Keys) {
    $sid = New-Sid
    $tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
    Write-Raw (Get-ControlPath $sid) $damaged[$kind]
    $r = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
    Check "$kind does not block a stop" ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
    $r = Invoke-Script 'pre-compact.ps1' @() (Get-CompactPayload $sid $tr)
    Check "$kind does not block a /compact" ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
    $control = Read-RawJson (Get-ControlPath $sid)
    Check "$kind is rewritten as conservative state" ($control -and $control.tier -eq 'deep' -and $control.recovered -eq $true -and $control.nudged.hardWrap -eq $true -and $control.nudged.compact -eq $true) ([System.IO.File]::ReadAllText((Get-ControlPath $sid)))
    Check "$kind is logged once" ((Get-RecoveredRows $sid) -eq 1) "rows=$(Get-RecoveredRows $sid)"
}

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 80000
Write-Raw (Get-ControlPath $sid) '{"tier":"routine","nudged":{"hardWr'
Write-Raw (Get-DiagPath $sid) '{"fails":2,"files":[],"bigWarned":0,"lowFailed":false}'
$r = Invoke-Script 'route.ps1' @() (Get-RoutePayload $sid $tr 'the race condition is still failing, fix it')
Check 'recovered state cannot re-arm the gear-max limit' ($r.code -eq 0 -and $r.text -notmatch 'gear=max') $r.text

$sid = New-Sid
Write-Raw (Get-ControlPath $sid) '{"tier":"deep","gear":"high","maxUses":1,"nudged":{"hardWrap":true}}'
Write-Raw (Get-DiagPath $sid) '{"fails":'
$r = Invoke-Script 'post-tool.ps1' @() (Get-FailurePayload $sid)
$control = Read-RawJson (Get-ControlPath $sid)
$diag = Read-RawJson (Get-DiagPath $sid)
Check 'malformed diagnostics only reset the counters' ($r.code -eq 0 -and $diag -and [int]$diag.fails -eq 1 -and $control.nudged.hardWrap -eq $true -and $control.tier -eq 'deep') ($diag | ConvertTo-Json -Compress -Depth 4)

$sid = New-Sid
Write-Raw (Get-DiagPath $sid) '{"fails":"several","files":[],"bigWarned":"some","lowFailed":false}'
$r = Invoke-Script 'post-tool.ps1' @() (Get-FailurePayload $sid)
$diag = Read-RawJson (Get-DiagPath $sid)
Check 'a counter of the wrong type restarts instead of disabling the hook' ($r.code -eq 0 -and $diag -and $diag.fails -eq 1 -and $diag.bigWarned -eq 0) ($diag | ConvertTo-Json -Compress -Depth 4)

# ---------- when the state cannot be used ----------
Write-Section 'no state means no interruption'

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
$lock = New-Object System.IO.FileStream((Join-Path $script:StateDir "$sid.lock"), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $r = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
    Check 'an unavailable lock does not block a stop' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
    Check 'an unavailable lock writes nothing' (-not (Test-Path -LiteralPath (Get-ControlPath $sid)))
} finally { $lock.Dispose() }
$r = Invoke-Script 'stop.ps1' @() (Get-StopPayload $sid $tr)
Check 'the interruption is still available afterwards' (Test-Blocked $r.text) $r.text

$r = Invoke-Script 'stop.ps1' @() (@{ cwd = $proj; hook_event_name = 'Stop'; stop_hook_active = $false; transcript_path = $tr } | ConvertTo-Json -Compress)
Check 'a hook with no session id does not block' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
$r = Invoke-Script 'pre-compact.ps1' @() (@{ cwd = $proj; hook_event_name = 'PreCompact'; trigger = 'manual'; transcript_path = $tr } | ConvertTo-Json -Compress)
Check 'a /compact with no session id is not blocked' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
Check 'a hook with no session id writes no shared state' (-not (Test-Path -LiteralPath (Join-Path $script:StateDir 'default.json')))

# ---------- resets ----------
Write-Section 'a session-start reset is an update like any other'

$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 200000
Write-Raw (Get-ControlPath $sid) '{"tier":"deep","gear":"high","maxUses":1,"nudged":{"compact":false,"hardWrap":true}}'
$a = New-BarrierPrefix
$b = New-BarrierPrefix
$heldA = Start-Held 'pre-compact.ps1' (Get-CompactPayload $sid $tr) $a
Check 'a /compact parks before writing its flag' (Wait-ForFile "$a.reached")
$startPayload = @{ session_id = $sid; cwd = $proj; hook_event_name = 'SessionStart'; source = 'compact' } | ConvertTo-Json -Compress
$heldB = Start-Contender 'session-start.ps1' $startPayload $b
Check 'the reset finds the lock taken' (Wait-ForFile "$b.waiting")
Write-Raw "$a.go" ''
$null = Wait-ScriptProcess $heldA
$null = Wait-ScriptProcess $heldB
$control = Read-RawJson (Get-ControlPath $sid)
Check 'the reset still clears the tier' ($control -and $control.tier -eq 'routine') ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the one-time flag set during the overlap survives it' ($control -and $control.nudged.compact -eq $true) ($control | ConvertTo-Json -Compress -Depth 4)
Check 'the effort limit survives it' ($control -and [int]$control.maxUses -eq 1) ($control | ConvertTo-Json -Compress -Depth 4)

Complete-TestRun 'state tests'
