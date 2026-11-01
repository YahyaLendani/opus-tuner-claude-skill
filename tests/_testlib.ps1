# Shared helpers for the reliability tests. Dot-source after setting $Interpreter.
#
# Every test runs the real scripts as separate processes against a throwaway
# config dir and state dir, so nothing here can touch a live install.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptDir = Join-Path (Join-Path (Join-Path $script:RepoRoot 'skills') 'opus-tuner') 'scripts'
$script:OnWin = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:pass = 0
$script:fail = 0

# A live Claude Code session exports these. Tests decide identity explicitly.
foreach ($v in @('CLAUDE_CODE_SESSION_ID', 'CLAUDE_SESSION_ID', 'CLAUDE_EFFORT')) {
    Remove-Item -LiteralPath "Env:$v" -ErrorAction SilentlyContinue
}

function New-TestSandbox {
    param([string]$Name)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("opus-tuner-$Name-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $script:Sandbox = $root
    $script:ClaudeDir = Join-Path $root 'claude'
    $script:StateDir = Join-Path $root 'state'
    New-Item -ItemType Directory -Force -Path $script:ClaudeDir, $script:StateDir | Out-Null
    $env:CLAUDE_CONFIG_DIR = $script:ClaudeDir
    $env:OPUS_TUNER_STATE = $script:StateDir
    $script:ConfigPath = Join-Path $root 'config.json'
    Set-TestConfig '{}'
    $env:OPUS_TUNER_CONFIG = $script:ConfigPath
    # The weekly digest is covered by the self-test; it would only add noise here.
    [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'digest.stamp'), 'test', $script:Utf8)
    # A regression that writes relative to the working directory lands in the
    # sandbox, not in the repository the tests run from.
    Push-Location -LiteralPath $root
    return $root
}

function Remove-TestSandbox {
    Pop-Location
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

function Set-TestConfig {
    param([string]$Json)
    [System.IO.File]::WriteAllText($script:ConfigPath, $Json, $script:Utf8)
}

function Get-TestInterpreter {
    param([string]$Requested)
    if ($Requested) { return $Requested }
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return 'pwsh' }
    return 'powershell'
}

function Get-ExePrefix {
    if ($script:OnWin) { return @('-NoProfile', '-ExecutionPolicy', 'Bypass') }
    return @('-NoProfile')
}

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:fail++
        if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) + '...' }
        Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Yellow
}

# Runs a script from the bundle. A missing script or a stderr line must show up
# as a failed assertion, not abort the whole test file.
function Invoke-Script {
    param([string]$Name, [string[]]$Arguments = @(), [string]$Stdin = '')
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # One element off Windows: without @() it unwraps to a string that does not splat.
        $prefix = @(Get-ExePrefix)
        $path = Join-Path $script:ScriptDir $Name
        if ($Stdin) {
            $out = $Stdin | & $script:Interpreter @prefix -File $path @Arguments 2>&1
        } else {
            $out = '' | & $script:Interpreter @prefix -File $path @Arguments 2>&1
        }
        $code = $LASTEXITCODE
        $text = (@($out | Where-Object { $_ -is [string] }) -join "`n").Trim()
        return @{ text = $text; code = $code }
    } finally { $ErrorActionPreference = $eap }
}

function Invoke-Hook {
    param([string]$Script, [hashtable]$Payload)
    return (Invoke-Script -Name $Script -Stdin ($Payload | ConvertTo-Json -Depth 10 -Compress))
}

# Starts a script without waiting, for the overlap tests.
function Start-ScriptProcess {
    param([string]$Name, [string[]]$Arguments = @(), [string]$Stdin = '')
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $script:Sandbox "in-$tag.json"
    $outFile = Join-Path $script:Sandbox "out-$tag.txt"
    $errFile = Join-Path $script:Sandbox "err-$tag.txt"
    [System.IO.File]::WriteAllText($inFile, $Stdin, $script:Utf8)
    $argv = @(Get-ExePrefix) + @('-File', "`"$(Join-Path $script:ScriptDir $Name)`"") + @($Arguments | ForEach-Object { "`"$_`"" })
    $p = Start-Process -FilePath $script:Interpreter -ArgumentList $argv -PassThru -NoNewWindow `
        -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    # Touching .Handle keeps the exit code readable after the process ends.
    $null = $p.Handle
    return @{ process = $p; out = $outFile; err = $errFile }
}

function Wait-ScriptProcess {
    param($Started, [int]$TimeoutMs = 60000)
    # Off Windows, Start-Process copies the output to the file as it arrives. The
    # timed overload can return before that is done; the plain one waits for it.
    if ($Started.process.WaitForExit($TimeoutMs)) { $Started.process.WaitForExit() }
    $text = ''
    if (Test-Path -LiteralPath $Started.out) { $text = [System.IO.File]::ReadAllText($Started.out).Trim() }
    return @{ text = $text; code = $Started.process.ExitCode }
}

function ConvertTo-ProjectFolder {
    param([string]$Path)
    return ($Path -replace '[^A-Za-z0-9]', '-')
}

# Writes <config>/projects/<encoded project>/<sid>.jsonl with the real record
# shape: a user record, then one assistant record per tool call.
function New-TestTranscript {
    param(
        [string]$Project,
        [string]$Sid,
        [string[]]$Files = @(),
        [string[]]$Commands = @(),
        [int64]$Ctx = 1000,
        [string]$Model = 'claude-opus-5-5'
    )
    $dir = Join-Path (Join-Path $script:ClaudeDir 'projects') (ConvertTo-ProjectFolder $Project)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir "$Sid.jsonl"
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((@{ type = 'user'; sessionId = $Sid; cwd = $Project; uuid = [guid]::NewGuid().ToString(); message = @{ role = 'user'; content = 'do the work' } } | ConvertTo-Json -Depth 10 -Compress))
    $n = 0
    $blocks = @()
    foreach ($f in $Files) { $blocks += , @{ name = 'Edit'; input = @{ file_path = $f; old_string = 'a'; new_string = 'b' } } }
    foreach ($c in $Commands) { $blocks += , @{ name = 'Bash'; input = @{ command = $c } } }
    if ($blocks.Count -eq 0) { $blocks = @(, @{ name = 'Read'; input = @{ file_path = (Join-Path $Project 'README.md') } }) }
    foreach ($b in $blocks) {
        $n++
        [void]$lines.Add((@{
            type = 'assistant'; sessionId = $Sid; cwd = $Project; uuid = [guid]::NewGuid().ToString(); requestId = "req_$n"
            message = @{
                id = "msg_${Sid}_$n"; role = 'assistant'; model = $Model
                content = @(@{ type = 'tool_use'; id = "toolu_$n"; name = $b.name; input = $b.input })
                usage = @{ input_tokens = 2; cache_read_input_tokens = $Ctx; cache_creation_input_tokens = 0; output_tokens = 30 }
            }
        } | ConvertTo-Json -Depth 10 -Compress))
    }
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $script:Utf8)
    return $path
}

function Get-HandoffFile {
    param([string]$Sid)
    return (Join-Path (Join-Path $script:StateDir 'handoffs') "$Sid.md")
}

# Replaces the body of one "## Title" section, as the model does when it fills
# the draft. Everything else in the file stays as written.
function Set-HandoffSection {
    param([string]$Path, [string]$Title, [string]$Body)
    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?ms)^## ' + [regex]::Escape($Title) + '[ \t]*\r?\n.*?(?=^## |\z)'
    $replacement = ("## $Title`n`n$Body`n`n").Replace('$', '$$')
    $new = [regex]::Replace($text, $pattern, $replacement)
    [System.IO.File]::WriteAllText($Path, $new, $script:Utf8)
}

function Set-HandoffComplete {
    param([string]$Path, [string]$Tag)
    Set-HandoffSection $Path 'Task goal' "Goal of $Tag."
    Set-HandoffSection $Path 'User constraints' "Constraint of $Tag."
    Set-HandoffSection $Path 'Decisions' "Decision of $Tag."
    Set-HandoffSection $Path 'Unresolved problems' 'None.'
    Set-HandoffSection $Path 'Verification results' "Tests of $Tag passed."
    Set-HandoffSection $Path 'Next step' "Next step of $Tag."
}

function Complete-TestRun {
    param([string]$Title)
    Write-Host ''
    if ($script:fail -gt 0) { Write-Host "$Title`: $($script:pass) passed, $($script:fail) failed" -ForegroundColor Red }
    else { Write-Host "$Title`: $($script:pass) passed, $($script:fail) failed" -ForegroundColor Green }
    Remove-TestSandbox
    if ($script:fail -gt 0) { exit 1 }
    exit 0
}
