# What each mode may do, what has to be asked for before anything interrupts a
# session, and what an upgrade does to settings that already exist.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/modes-test.ps1
#   pwsh -NoProfile -File tests/modes-test.ps1

param([string]$Interpreter = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Interpreter = Get-TestInterpreter $Interpreter
$null = New-TestSandbox 'modes'

$proj = Join-Path $script:Sandbox 'project'
New-Item -ItemType Directory -Force -Path $proj | Out-Null
$script:DecisionLog = Join-Path $script:StateDir 'decisions.csv'

Write-Host "modes tests  (interpreter: $($script:Interpreter))" -ForegroundColor Cyan

function New-Sid { return [guid]::NewGuid().ToString('N').Substring(0, 12) + '-modes' }

function Test-Blocked { param([string]$Text) return ($Text -match '"decision"\s*:\s*"block"') }
function Test-Denied { param([string]$Text) return ($Text -match '"permissionDecision"\s*:\s*"deny"') }
function Test-HasContext { param([string]$Text) return ($Text -match 'additionalContext') }

function Invoke-Stop {
    param([string]$Sid, [int64]$Ctx = 200000)
    $tr = New-TestTranscript -Project $proj -Sid $Sid -Ctx $Ctx
    return (Invoke-Hook 'stop.ps1' @{ session_id = $Sid; cwd = $proj; transcript_path = $tr; hook_event_name = 'Stop'; stop_hook_active = $false })
}

function Invoke-Compact {
    param([string]$Sid, [string]$Trigger = 'manual', [int64]$Ctx = 200000)
    $tr = New-TestTranscript -Project $proj -Sid $Sid -Ctx $Ctx
    return (Invoke-Hook 'pre-compact.ps1' @{ session_id = $Sid; cwd = $proj; transcript_path = $tr; hook_event_name = 'PreCompact'; trigger = $Trigger })
}

function Invoke-Route {
    param([string]$Sid, [string]$Prompt = 'carry on', [int64]$Ctx = 200000)
    $tr = New-TestTranscript -Project $proj -Sid $Sid -Ctx $Ctx
    return (Invoke-Hook 'route.ps1' @{ session_id = $Sid; cwd = $proj; transcript_path = $tr; hook_event_name = 'UserPromptSubmit'; prompt = $Prompt; permission_mode = 'default' })
}

function Invoke-ReadGuard {
    param([string]$Sid, [int]$Limit = 0)
    $tr = New-TestTranscript -Project $proj -Sid $Sid -Ctx 200000
    $input_ = @{ file_path = (Join-Path $proj 'big.txt') }
    if ($Limit -gt 0) { $input_['limit'] = $Limit }
    return (Invoke-Hook 'pre-tool.ps1' @{ session_id = $Sid; cwd = $proj; transcript_path = $tr; hook_event_name = 'PreToolUse'; tool_name = 'Read'; tool_input = $input_ })
}

function Get-Tier {
    param([string]$Sid)
    $p = Join-Path $script:StateDir "$Sid.json"
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    return [string]([System.IO.File]::ReadAllText($p) | ConvertFrom-Json).tier
}

function Get-Actions {
    param([string]$Sid)
    if (-not (Test-Path -LiteralPath $script:DecisionLog)) { return @() }
    return @(Import-Csv -LiteralPath $script:DecisionLog | Where-Object { $_.session -eq $Sid.Substring(0, 8) } | ForEach-Object { $_.action })
}

# ---------- the default interrupts nothing ----------
Write-Section 'with no settings, nothing is interrupted'
Set-TestConfig '{}'

$sid = New-Sid
$r = Invoke-Stop $sid
Check 'a stop at the ceiling is allowed' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
Check 'the stop still shows advice' ($r.text -match 'systemMessage' -and $r.text -match '/wrap' -and $r.text -match '/clear') $r.text

$sid = New-Sid
$r = Invoke-Compact $sid
Check 'a manual /compact is allowed' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
Check 'the compaction is still logged' ((Get-Actions $sid) -contains 'compact-manual') ((Get-Actions $sid) -join ',')

$sid = New-Sid
$r = Invoke-ReadGuard $sid
Check 'a bulk read is allowed' ($r.code -eq 0 -and -not (Test-Denied $r.text)) $r.text

$sid = New-Sid
$r = Invoke-Route $sid
Check 'the prompt hook still advises at the ceiling' (Test-HasContext $r.text) $r.text
Check 'the advice leaves the choice to the user' ($r.text -match 'If the user wants to continue in a fresh session' -and $r.text -match 'ask them to run /clear') $r.text
Check 'the advice does not order a stop' ($r.text -notmatch 'Stop starting new work') $r.text
Check 'the advice does not mention a prompt that will not come' ($r.text -notmatch 'Stop hook|one-time') $r.text

$sid = New-Sid
$r = Invoke-Stop $sid 160000
Check 'a tier can still step up' ($r.text -match 'escalated' -and (Get-Tier $sid) -eq 'deep') $r.text

# ---------- a key alone does nothing ----------
Write-Section 'an interruption needs guard mode and its own key'

$notEnough = [ordered]@{
    'hardWrap alone'                 = '{"hardWrap":true,"blockManualCompact":true}'
    'assist with both keys'          = '{"mode":"assist","hardWrap":true,"blockManualCompact":true}'
    'the old advise name with both'  = '{"mode":"advise","hardWrap":true,"blockManualCompact":true}'
    'guard with neither key'         = '{"mode":"guard"}'
    'guard with the keys off'        = '{"mode":"guard","hardWrap":false,"blockManualCompact":false}'
    'guard with the words as strings' = '{"mode":"guard","hardWrap":"false","blockManualCompact":"true"}'
    'guard with numbers'             = '{"mode":"guard","hardWrap":1,"blockManualCompact":1}'
}
foreach ($kind in $notEnough.Keys) {
    Set-TestConfig $notEnough[$kind]
    $r = Invoke-Stop (New-Sid)
    Check "$kind does not block a stop" ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
    $r = Invoke-Compact (New-Sid)
    Check "$kind does not block a /compact" ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
}

# ---------- guard ----------
Write-Section 'guard fires what it was told to, once'

Set-TestConfig '{"mode":"guard","hardWrap":true}'
$sid = New-Sid
$r = Invoke-Stop $sid
Check 'guard with hardWrap blocks the stop' (Test-Blocked $r.text) $r.text
Check 'the prompt calls itself one-time' ($r.text -match 'one-time') $r.text
Check 'the prompt says the next stop is allowed' ($r.text -match 'next stop will be allowed') $r.text
Check 'the prompt says it is not a limit' ($r.text -match 'not a limit') $r.text
Check 'the prompt asks the user to run /clear' ($r.text -match '/wrap' -and $r.text -match 'ask the user to run /clear') $r.text
Check 'the prompt allows for finished work' ($r.text -match 'If the work is done') $r.text
Check 'the prompt forbids nothing it cannot enforce' ($r.text -notmatch 'Do not /compact|Do not start new work|four sections') $r.text
$r = Invoke-Stop $sid
Check 'the next stop is allowed' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
$r = Invoke-Compact (New-Sid)
Check 'hardWrap does not switch on the /compact block' (-not (Test-Blocked $r.text)) $r.text
$r = Invoke-Route (New-Sid)
Check 'the prompt hook names the coming stop prompt' ($r.text -match 'one-time') $r.text

Set-TestConfig '{"mode":"guard","blockManualCompact":true}'
$sid = New-Sid
$r = Invoke-Compact $sid
Check 'guard with blockManualCompact blocks a manual /compact' (Test-Blocked $r.text) $r.text
Check 'the refusal keeps /wrap and /clear' ($r.text -match '/wrap' -and $r.text -match '/clear') $r.text
Check 'the refusal makes no cost claim' ($r.text -notmatch '500 tokens|re-reads the entire|buys nothing') $r.text
Check 'the refusal names no shared handoff file' ($r.text -notmatch 'handoff\.md') $r.text
Check 'the refusal says how to go ahead' ($r.text -match 'Run /compact again|run /compact again') $r.text
$r = Invoke-Compact $sid
Check 'the second /compact is allowed' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
$r = Invoke-Compact (New-Sid) 'auto'
Check 'automatic compaction is never blocked' ($r.code -eq 0 -and -not (Test-Blocked $r.text)) $r.text
$r = Invoke-Stop (New-Sid)
Check 'blockManualCompact does not switch on the stop prompt' (-not (Test-Blocked $r.text)) $r.text

Set-TestConfig '{"mode":"guard"}'
$r = Invoke-ReadGuard (New-Sid)
Check 'guard denies a bulk read at the ceiling' (Test-Denied $r.text) $r.text
Check 'the denial leaves /clear to the user' ($r.text -match 'ask them to run /clear') $r.text
$r = Invoke-ReadGuard (New-Sid) 200
Check 'guard allows a bounded read' (-not (Test-Denied $r.text)) $r.text

# ---------- older names ----------
Write-Section 'older mode names keep working'

Set-TestConfig '{"mode":"enforce"}'
$r = Invoke-Stop (New-Sid)
Check 'enforce still blocks the stop' (Test-Blocked $r.text) $r.text
$r = Invoke-Compact (New-Sid)
Check 'enforce still blocks a manual /compact' (Test-Blocked $r.text) $r.text
$r = Invoke-ReadGuard (New-Sid)
Check 'enforce still guards reads' (Test-Denied $r.text) $r.text

Set-TestConfig '{"mode":"enforce","hardWrap":false}'
$r = Invoke-Stop (New-Sid)
Check 'enforce respects an explicit hardWrap off' (-not (Test-Blocked $r.text)) $r.text
$r = Invoke-Compact (New-Sid)
Check 'and still blocks the /compact it was not told to skip' (Test-Blocked $r.text) $r.text

Set-TestConfig '{"mode":"advise"}'
$r = Invoke-Route (New-Sid)
Check 'advise acts as assist' (Test-HasContext $r.text) $r.text
$r = Invoke-ReadGuard (New-Sid)
Check 'advise does not guard reads' (-not (Test-Denied $r.text)) $r.text

Set-TestConfig '{"mode":" GUARD ","hardWrap":true}'
$r = Invoke-Stop (New-Sid)
Check 'mode names ignore case and spaces' (Test-Blocked $r.text) $r.text

Set-TestConfig '{"mode":"strict","hardWrap":true,"blockManualCompact":true}'
$r = Invoke-Stop (New-Sid)
Check 'an unknown mode interrupts nothing' (-not (Test-Blocked $r.text)) $r.text
$r = Invoke-Route (New-Sid)
Check 'an unknown mode falls back to assist' (Test-HasContext $r.text) $r.text
$r = Invoke-Hook 'session-start.ps1' @{ session_id = (New-Sid); cwd = $proj; hook_event_name = 'SessionStart'; source = 'startup' }
Check 'an unknown mode is reported' ($r.text -match 'systemMessage' -and $r.text -match 'strict') $r.text

# ---------- monitor ----------
Write-Section 'monitor only shows numbers'
Set-TestConfig '{"mode":"monitor","hardWrap":true,"blockManualCompact":true}'

$sid = New-Sid
$r = Invoke-Route $sid 'the race condition is back, refactor it'
Check 'the prompt hook adds nothing' ($r.code -eq 0 -and $r.text.Length -eq 0) $r.text
Check 'the prompt hook changes no tier' ((Get-Tier $sid) -ne 'deep') (Get-Tier $sid)

$sid = New-Sid
$big = 'x' * 60000
$r = Invoke-Hook 'post-tool.ps1' @{ session_id = $sid; cwd = $proj; hook_event_name = 'PostToolUse'; tool_name = 'Read'; tool_response = @{ text = $big } }
Check 'the tool hook adds nothing' ($r.code -eq 0 -and $r.text.Length -eq 0) ($r.text.Substring(0, [Math]::Min(200, $r.text.Length)))
Check 'the tool hook keeps no counters' (-not (Test-Path -LiteralPath (Join-Path $script:StateDir "$sid.diag.json")))

$sid = New-Sid
$r = Invoke-Stop $sid 160000
Check 'a stop in the grace band does not escalate' ($r.text -notmatch 'escalated' -and (Get-Tier $sid) -ne 'deep') $r.text

$sid = New-Sid
$r = Invoke-Stop $sid
Check 'a stop at the ceiling shows the number' ($r.text -match 'systemMessage' -and $r.text -match '200k') $r.text
Check 'a stop at the ceiling does not block' (-not (Test-Blocked $r.text)) $r.text
Check 'a stop at the ceiling gives no instruction' ($r.text -notmatch '/wrap|/clear') $r.text
$r = Invoke-Compact (New-Sid)
Check 'a manual /compact is allowed' (-not (Test-Blocked $r.text)) $r.text
$r = Invoke-ReadGuard (New-Sid)
Check 'a bulk read is allowed' (-not (Test-Denied $r.text)) $r.text

Set-TestConfig '{"mode":"monitor","profile":"creative"}'
$r = Invoke-Hook 'session-start.ps1' @{ session_id = (New-Sid); cwd = $proj; hook_event_name = 'SessionStart'; source = 'startup' }
Check 'session start adds no profile note' (-not (Test-HasContext $r.text)) $r.text
Set-TestConfig '{"mode":"assist","profile":"creative"}'
$r = Invoke-Hook 'session-start.ps1' @{ session_id = (New-Sid); cwd = $proj; hook_event_name = 'SessionStart'; source = 'startup' }
Check 'assist does add it' (Test-HasContext $r.text) $r.text

# A handoff the user asked for is still theirs, but monitor adds nothing to the model.
Set-TestConfig '{"mode":"monitor"}'
$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 90000
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sid, '-Transcript', $tr, '-Project', $proj)
Check 'monitor can still write a handoff on request' ($r.code -eq 0) $r.text
$path = Get-HandoffFile $sid
Set-HandoffComplete $path 'monitored'
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sid, '-Verify')
Check 'and verify it' ($r.code -eq 0) $r.text
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sid; cwd = $proj; hook_event_name = 'SessionEnd'; reason = 'clear' }
$r = Invoke-Hook 'session-start.ps1' @{ session_id = (New-Sid); cwd = $proj; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'the next session does not load it' (-not (Test-HasContext $r.text)) $r.text
Check 'the next session says where it is' ($r.text -match 'systemMessage' -and $r.text -match [regex]::Escape((Split-Path -Leaf $path))) $r.text
Check 'the handoff stays where it was' (Test-Path -LiteralPath $path)
Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue

# Every session-start note describes what was seen, and never prices it.
Set-TestConfig '{}'
$sid = New-Sid
$tr = New-TestTranscript -Project $proj -Sid $sid -Ctx 260000
$r = Invoke-Hook 'session-start.ps1' @{ session_id = $sid; cwd = $proj; transcript_path = $tr; hook_event_name = 'SessionStart'; source = 'resume' }
Check 'the resume note keeps the context size' ($r.text -match 'resuming at 260k') $r.text
Check 'the resume note makes no cost claim' ($r.text -notmatch '\$\d|500 tokens|cache-read rates') $r.text

# ---------- installer ----------
Write-Section 'upgrades keep what was chosen'

function New-InstallDir {
    $d = Join-Path $script:Sandbox ('install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Invoke-Install {
    param([string]$Dir, [string[]]$Arguments = @('-Force'))
    $env:CLAUDE_CONFIG_DIR = $Dir
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $prefix = @(Get-ExePrefix)
        $out = '' | & $script:Interpreter @prefix -File (Join-Path $script:RepoRoot 'install.ps1') @Arguments 2>&1
        $code = $LASTEXITCODE
        return @{ text = (@($out | ForEach-Object { [string]$_ }) -join "`n"); code = $code }
    } finally {
        $ErrorActionPreference = $eap
        $env:CLAUDE_CONFIG_DIR = $script:ClaudeDir
    }
}

function Write-InstalledConfig {
    param([string]$Dir, [string]$Json)
    [System.IO.File]::WriteAllText((Join-Path $Dir 'tuner.config.json'), $Json, $script:Utf8)
}

function Read-InstalledConfig {
    param([string]$Dir)
    return ([System.IO.File]::ReadAllText((Join-Path $Dir 'tuner.config.json')) | ConvertFrom-Json)
}

function Get-ConfigBackups {
    param([string]$Dir)
    return @(Get-ChildItem -LiteralPath $Dir -Filter 'tuner.config.json.bak-*' -File)
}

$d = New-InstallDir
$r = Invoke-Install $d
Check 'a fresh install succeeds' ($r.code -eq 0) $r.text
Check 'a fresh install writes no settings it was not given' (-not (Test-Path -LiteralPath (Join-Path $d 'tuner.config.json')))
Check 'a fresh install names the default mode' ($r.text -match 'assist') $r.text
Check 'a fresh install says how to turn interruptions on' ($r.text -match 'guard' -and $r.text -match 'hardWrap' -and $r.text -match 'blockManualCompact') $r.text

$d = New-InstallDir
$settings = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"& \"C:/old/.claude/skills/opus-tuner/scripts/stop.ps1\""}]}]}}'
[System.IO.File]::WriteAllText((Join-Path $d 'settings.json'), $settings, $script:Utf8)
$r = Invoke-Install $d
Check 'an upgrade with no settings explains the changed default' ($r.text -match 'on by default' -and $r.text -match 'hardWrap' -and $r.text -match 'blockManualCompact') $r.text

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"enforce","routineTokens":120000}'
$r = Invoke-Install $d
$c = Read-InstalledConfig $d
Check 'enforce becomes guard with both interruptions' ($c.mode -eq 'guard' -and $c.hardWrap -eq $true -and $c.blockManualCompact -eq $true) ($c | ConvertTo-Json -Compress)
Check 'other settings are kept' ([int]$c.routineTokens -eq 120000) ($c | ConvertTo-Json -Compress)
$backups = Get-ConfigBackups $d
Check 'the old file is backed up' ($backups.Count -eq 1 -and [System.IO.File]::ReadAllText($backups[0].FullName) -match 'enforce') (@($backups.Name) -join ',')
Check 'the change is explained' ($r.text -match 'enforce' -and $r.text -match 'guard') $r.text
$before = [System.IO.File]::ReadAllText((Join-Path $d 'tuner.config.json'))
$r = Invoke-Install $d
Check 'a second install changes nothing' ([System.IO.File]::ReadAllText((Join-Path $d 'tuner.config.json')) -ceq $before -and (Get-ConfigBackups $d).Count -eq 1) $r.text

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"enforce","hardWrap":false}'
$null = Invoke-Install $d
$c = Read-InstalledConfig $d
Check 'enforce keeps an explicit hardWrap off' ($c.mode -eq 'guard' -and $c.hardWrap -eq $false -and $c.blockManualCompact -eq $true) ($c | ConvertTo-Json -Compress)

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"advise","hardWrap":true}'
$r = Invoke-Install $d
$c = Read-InstalledConfig $d
Check 'an explicit hardWrap moves advise to guard' ($c.mode -eq 'guard' -and $c.hardWrap -eq $true) ($c | ConvertTo-Json -Compress)
Check 'and adds no key that was not chosen' ($null -eq $c.PSObject.Properties['blockManualCompact']) ($c | ConvertTo-Json -Compress)
Check 'and explains what is now off' ($r.text -match 'blockManualCompact') $r.text

$d = New-InstallDir
Write-InstalledConfig $d '{"blockManualCompact":true}'
$null = Invoke-Install $d
$c = Read-InstalledConfig $d
Check 'an explicit blockManualCompact with no mode moves to guard' ($c.mode -eq 'guard' -and $c.blockManualCompact -eq $true) ($c | ConvertTo-Json -Compress)

$unchanged = [ordered]@{
    'off'                   = '{"mode":"off","hardWrap":true}'
    'an explicit assist'    = '{"mode":"assist","hardWrap":true}'
    'an explicit monitor'   = '{"mode":"monitor","blockManualCompact":true}'
    'an explicit guard'     = '{"mode":"guard","hardWrap":true}'
    'advise with nothing to keep' = '{"mode":"advise","hardWrap":false}'
    'invalid JSON'          = '{"mode":'
}
foreach ($kind in $unchanged.Keys) {
    $d = New-InstallDir
    Write-InstalledConfig $d $unchanged[$kind]
    $r = Invoke-Install $d
    Check "$kind is left as written" ($r.code -eq 0 -and [System.IO.File]::ReadAllText((Join-Path $d 'tuner.config.json')) -ceq $unchanged[$kind] -and (Get-ConfigBackups $d).Count -eq 0) $r.text
}

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"advise"}'
$r = Invoke-Install $d
Check 'advise with no choices is told about the changed default' ($r.text -match 'on by default') $r.text

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"enforce"}'
$r = Invoke-Install $d @('-Force', '-DryRun')
Check 'a dry run changes nothing' ([System.IO.File]::ReadAllText((Join-Path $d 'tuner.config.json')) -ceq '{"mode":"enforce"}') $r.text
Check 'a dry run says what it would do' ($r.text -match 'would' -and $r.text -match 'guard') $r.text

# Without -Force the installed scripts stay, and older ones do not know guard.
$d = New-InstallDir
$oldScripts = Join-Path (Join-Path (Join-Path $d 'skills') 'opus-tuner') 'scripts'
New-Item -ItemType Directory -Force -Path $oldScripts | Out-Null
[System.IO.File]::WriteAllText((Join-Path $oldScripts 'stop.ps1'), "exit 0`n", $script:Utf8)
Write-InstalledConfig $d '{"mode":"enforce"}'
$r = Invoke-Install $d @()
Check 'older installed scripts keep the old settings' ([System.IO.File]::ReadAllText((Join-Path $d 'tuner.config.json')) -ceq '{"mode":"enforce"}') $r.text
Check 'and say what to run' ($r.text -match '-Force') $r.text

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"enforce"}'
$null = Invoke-Install $d @('-Force', '-Enforce')
$null = Invoke-Install $d
$s = [System.IO.File]::ReadAllText((Join-Path $d 'settings.json')) | ConvertFrom-Json
Check 'an upgrade keeps a read guard already in use' ($null -ne $s.hooks.PSObject.Properties['PreToolUse'] -and @($s.hooks.PreToolUse).Count -eq 1) ($s.hooks | ConvertTo-Json -Depth 6 -Compress)

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"guard"}'
$null = Invoke-Install $d @('-Force', '-Enforce')
Write-InstalledConfig $d '{"mode":"assist"}'
$null = Invoke-Install $d
$s = [System.IO.File]::ReadAllText((Join-Path $d 'settings.json')) | ConvertFrom-Json
Check 'leaving guard removes the read guard' ($null -eq $s.hooks.PSObject.Properties['PreToolUse'] -or @($s.hooks.PreToolUse).Count -eq 0) ($s.hooks | ConvertTo-Json -Depth 6 -Compress)

$d = New-InstallDir
Write-InstalledConfig $d '{"mode":"enforce"}'
$r = Invoke-Install $d @('-Force', '-NoHooks')
Check 'an advisory install leaves the settings alone' ([System.IO.File]::ReadAllText((Join-Path $d 'tuner.config.json')) -ceq '{"mode":"enforce"}') $r.text

# ---------- CLAUDE.md ----------
Write-Section 'the CLAUDE.md block'

$oldBlock = @'
<!-- opus-tuner:begin -->
# token discipline
- Batch independent tool calls in one message; every turn re-reads all context.
- Grep before Read; bound reads with offset/limit.
- A `[tuner] gear=X` line means invoke `/gear-X` first.
- Send breadth (locating code, many files, suites) to a subagent; keep judgement local.
- At a task boundary, or 70% of the tier ceiling: `/wrap`, then tell the user to `/clear`. Never `/compact` at a boundary.
- Never trade verification for tokens.
<!-- opus-tuner:end -->
'@ -replace "`r`n", "`n"

foreach ($ending in @("`n", "`r`n")) {
    $label = if ($ending -eq "`n") { 'LF' } else { 'CRLF' }
    $d = New-InstallDir
    $md = Join-Path $d 'CLAUDE.md'
    [System.IO.File]::WriteAllText($md, (("# my rules`nkeep me`n`n" + $oldBlock + "`n`n# after`nme too`n") -replace "`n", $ending), $script:Utf8)
    $r = Invoke-Install $d
    $text = [System.IO.File]::ReadAllText($md)
    Check "the known old block is replaced ($label)" ($text -notmatch 'Never `/compact`' -and $text -match 'When the user wants to continue in a fresh session') $text
    Check "the text around it stays ($label)" ($text -match 'keep me' -and $text -match 'me too') $text
    Check "the block is not duplicated ($label)" (([regex]::Matches($text, 'opus-tuner:begin')).Count -eq 1) $text
    Check "the old file is backed up ($label)" (@(Get-ChildItem -LiteralPath $d -Filter 'CLAUDE.md.bak-*' -File).Count -eq 1)
}

$d = New-InstallDir
$md = Join-Path $d 'CLAUDE.md'
$custom = $oldBlock.Replace('Never trade verification for tokens.', 'My own last rule.')
[System.IO.File]::WriteAllText($md, $custom, $script:Utf8)
$r = Invoke-Install $d
Check 'an edited block is kept as written' ([System.IO.File]::ReadAllText($md) -ceq $custom) ([System.IO.File]::ReadAllText($md))
Check 'with a note about the new wording' ($r.text -match 'CLAUDE\.md|block' -and $r.text -match 'edited') $r.text

$d = New-InstallDir
$md = Join-Path $d 'CLAUDE.md'
[System.IO.File]::WriteAllText($md, "# my rules`n", $script:Utf8)
$r = Invoke-Install $d
$text = [System.IO.File]::ReadAllText($md)
Check 'a new block makes no standing cost claim' ($text -notmatch 'Never `/compact`|70% of the tier') $text
Check 'a new block leaves /clear to the user' ($text -match 'ask them to run `/clear`') $text
$before = $text
$null = Invoke-Install $d
Check 'a current block is not touched again' ([System.IO.File]::ReadAllText($md) -ceq $before)

# ---------- doctor ----------
Write-Section 'doctor reports what will actually happen'

function Invoke-Doctor {
    param([string]$Dir, [string]$Json)
    Write-InstalledConfig $Dir $Json
    $saved = $env:OPUS_TUNER_CONFIG
    $savedState = $env:OPUS_TUNER_STATE
    $env:OPUS_TUNER_CONFIG = Join-Path $Dir 'tuner.config.json'
    $env:CLAUDE_CONFIG_DIR = $Dir
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $prefix = @(Get-ExePrefix)
        $doctor = Join-Path (Join-Path (Join-Path (Join-Path $Dir 'skills') 'opus-tuner') 'scripts') 'doctor.ps1'
        $out = '' | & $script:Interpreter @prefix -File $doctor 2>&1
        $code = $LASTEXITCODE
        return @{ text = (@($out | ForEach-Object { [string]$_ }) -join "`n"); code = $code }
    } finally {
        $ErrorActionPreference = $eap
        $env:OPUS_TUNER_CONFIG = $saved
        $env:OPUS_TUNER_STATE = $savedState
        $env:CLAUDE_CONFIG_DIR = $script:ClaudeDir
    }
}

$d = New-InstallDir
$null = Invoke-Install $d

$r = Invoke-Doctor $d '{}'
Check 'the default is healthy' ($r.text -match 'healthy') $r.text
Check 'it says nothing interrupts' ($r.text -match 'interruptions: none') $r.text

$r = Invoke-Doctor $d '{"mode":"assist","hardWrap":true}'
Check 'a key with no effect is flagged' ($r.text -match 'hardWrap' -and $r.text -match 'no effect') $r.text
Check 'but is not a failure' ($r.text -match 'healthy') $r.text

$r = Invoke-Doctor $d '{"mode":"guard"}'
Check 'guard with nothing configured is flagged' ($r.text -match 'nothing configured') $r.text

$r = Invoke-Doctor $d '{"mode":"guard","hardWrap":"true"}'
Check 'a key that is not a real true is flagged' ($r.text -match 'hardWrap' -and $r.text -match 'true or false') $r.text

$r = Invoke-Doctor $d '{"mode":"guard","hardWrap":true,"blockManualCompact":true}'
Check 'guard lists what can interrupt' ($r.text -match 'interruptions:.*Stop' -and $r.text -match 'interruptions:.*compact') $r.text

$r = Invoke-Doctor $d '{"mode":"enforce"}'
Check 'an old mode name is accepted' ($r.text -match 'healthy') $r.text

$r = Invoke-Doctor $d '{"mode":"monitor"}'
Check 'monitor mode replays as healthy' ($r.text -match 'healthy') $r.text

$r = Invoke-Doctor $d '{"mode":"strict"}'
Check 'an unknown mode fails the check' ($r.code -ne 0 -and $r.text -match 'mode is a known value') $r.text

Complete-TestRun 'modes tests'
