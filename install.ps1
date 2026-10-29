# opus-tuner installer.
#
# Copies the skills and merges the hook wiring into settings.json without
# touching hooks you already have. Idempotent: running it twice does not
# duplicate entries. Every settings write is preceded by a timestamped backup.
#
# Windows (built in):
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Force
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Enforce
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -DryRun
#
# macOS / Linux (needs pwsh 7: brew install --cask powershell, apt, or snap):
#   ./install.sh                 # wrapper that checks for pwsh
#   pwsh -NoProfile -File install.ps1 -Force
#
# -NoHooks installs the skills and the CLAUDE.md block only, for machines where
# hooks cannot run. See docs/platforms.md.
#
# Target: $env:CLAUDE_CONFIG_DIR if set, otherwise ~/.claude.

[CmdletBinding()]
param(
    # Replace skill folders that already exist (they are backed up first).
    [switch]$Force,
    # Also register the optional PreToolUse Read guard (mode must be "enforce").
    [switch]$Enforce,
    # Do not add the token-discipline block to CLAUDE.md.
    [switch]$SkipClaudeMd,
    # Do not install the status line.
    [switch]$NoStatusLine,
    # Do not touch settings.json at all: skills + CLAUDE.md only.
    [switch]$NoHooks,
    # Print the merged settings instead of writing anything.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Read before anything is copied: the banner is the only place a user sees which
# build they are about to install, and it is the string SECURITY.md asks reporters
# for.
$Version = 'unknown'
$versionFile = Join-Path (Join-Path $PSScriptRoot 'skills') (Join-Path 'opus-tuner' 'VERSION')
if (Test-Path -LiteralPath $versionFile) {
    $raw = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    if ($raw) { $Version = $raw }
}

# Same platform layer as _common.ps1. The installer stays standalone on purpose:
# it must work even when the scripts it is about to copy are half-present.
$OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE }
           elseif ($env:HOME) { $env:HOME }
           else { [System.Environment]::GetFolderPath('UserProfile') }

if (-not $OnWindows -and -not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    throw "pwsh 7 is required on macOS/Linux because Claude Code runs the hooks with it. Install it first: macOS 'brew install --cask powershell', Ubuntu 'snap install powershell --classic', or https://aka.ms/powershell"
}

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HomeDir '.claude' }
$skillsDir = Join-Path $claudeDir 'skills'
$settingsPath = Join-Path $claudeDir 'settings.json'
$claudeMdPath = Join-Path $claudeDir 'CLAUDE.md'
$backupDir = Join-Path (Join-Path $claudeDir 'state') 'opus-tuner-backups'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$nl = if ($OnWindows) { "`r`n" } else { "`n" }

$skills = @('opus-tuner', 'claude-skill', 'gear-low', 'gear-medium', 'gear-xhigh', 'gear-max', 'wrap', 'profile')

function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-Hashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $out = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { [void]$out.Add((ConvertTo-Hashtable $i)) }
        return , $out
    }
    $h = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
    return $h
}

function Get-ScriptCommand {
    param([string]$Name)
    $p = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') $Name
    if ($OnWindows) {
        # Claude Code runs this through PowerShell; the & call operator is the
        # portable way to run a quoted script path.
        return "& `"$($p -replace '\\', '/')`""
    }
    # POSIX hooks are spawned by sh, so name the interpreter explicitly.
    return "pwsh -NoProfile -File `"$p`""
}

function Get-StatusLineCommand {
    $p = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') 'statusline.ps1'
    if ($OnWindows) {
        return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($p -replace '\\', '/')`""
    }
    return "pwsh -NoProfile -File `"$p`""
}

function New-HookGroup {
    param([string]$Script, [string]$Matcher = '', [int]$Timeout = 10, [switch]$Async)
    $hook = @{
        type    = 'command'
        shell   = $(if ($OnWindows) { 'powershell' } else { 'bash' })
        command = (Get-ScriptCommand $Script)
        timeout = $Timeout
    }
    if ($Async) { $hook['async'] = $true }
    $group = @{ hooks = @($hook) }
    if ($Matcher) { $group['matcher'] = $Matcher }
    return $group
}

# Removes any group that points at this bundle, keeps everything else. That is
# what makes an upgrade replace our hooks without duplicating them, and what
# keeps the user's own hooks intact.
function Set-OurHook {
    param($Hooks, [string]$Event, $Group)
    if (-not $Hooks.Contains($Event)) { $Hooks[$Event] = @() }
    $kept = @(@($Hooks[$Event]) | Where-Object {
        $cmds = @($_.hooks | ForEach-Object { [string]$_['command'] }) -join ' '
        $cmds -notmatch 'opus-tuner[/\\]scripts[/\\]'
    })
    if ($null -ne $Group) { $kept = @($kept) + $Group }
    $Hooks[$Event] = $kept
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 20
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

Write-Host ''
Write-Host "opus-tuner $Version" -ForegroundColor Cyan
Write-Host "install -> $claudeDir"
if ($DryRun) { Write-Host 'dry run: nothing will be written' -ForegroundColor Yellow }
elseif (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null }

# ---------- 1. skills ----------
Write-Host ''
Write-Host 'skills' -ForegroundColor Yellow
foreach ($s in $skills) {
    $src = Join-Path (Join-Path $PSScriptRoot 'skills') $s
    $dst = Join-Path $skillsDir $s
    if (-not (Test-Path -LiteralPath $src)) { throw "missing source folder: $src" }

    if ((Test-Path -LiteralPath $dst) -and -not $Force) {
        Write-Host "  skip   $s (exists; use -Force to replace)"
        continue
    }
    if ($DryRun) {
        Write-Host "  would  $s"
        continue
    }
    if (Test-Path -LiteralPath $dst) {
        # Back up outside skills/, or Claude Code would load the backup as a
        # second skill with the same name.
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
        Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir "$s-$stamp") -Recurse -Force
        Remove-Item -LiteralPath $dst -Recurse -Force
    }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    Write-Host "  ok     $s"
}

# ---------- 2. settings.json ----------
Write-Host ''
Write-Host 'hooks and status line' -ForegroundColor Yellow

if ($NoHooks) {
    # Advisory mode: skills and CLAUDE.md only. settings.json is not read, so a
    # machine with a locked-down or absent config is never touched.
    Write-Host '  skip   settings.json (-NoHooks: advisory mode, no automation)'
    if (Test-Path -LiteralPath $settingsPath) {
        $existing = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        if ($existing -match 'opus-tuner[/\\]scripts[/\\]') {
            Write-Host '  note   settings.json still has opus-tuner hooks from an earlier install;' -ForegroundColor Yellow
            Write-Host '         run uninstall.ps1 -KeepSkills first if you want them gone.' -ForegroundColor Yellow
        }
    }
}

$settings = @{}
if (-not $NoHooks) {
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = ConvertTo-Hashtable (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch {
            throw "settings.json is not valid JSON; fix it before installing: $settingsPath"
        }
        if (-not ($settings -is [System.Collections.IDictionary])) { $settings = @{} }
    }
    if (-not $settings.Contains('hooks')) { $settings['hooks'] = @{} }
    $hooks = $settings['hooks']

    Set-OurHook $hooks 'UserPromptSubmit' (New-HookGroup 'route.ps1')
    Set-OurHook $hooks 'PostToolUse' (New-HookGroup 'post-tool.ps1' 'Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell' 10 -Async)
    Set-OurHook $hooks 'PostToolUseFailure' (New-HookGroup 'post-tool.ps1' '' 10 -Async)
    Set-OurHook $hooks 'Stop' (New-HookGroup 'stop.ps1')
    Set-OurHook $hooks 'SessionStart' (New-HookGroup 'session-start.ps1' 'startup|resume|clear|compact|fork' 15)
    Set-OurHook $hooks 'PreCompact' (New-HookGroup 'pre-compact.ps1' 'manual|auto')
    if ($Enforce) {
        Set-OurHook $hooks 'PreToolUse' (New-HookGroup 'pre-tool.ps1' 'Read')
    } else {
        Set-OurHook $hooks 'PreToolUse' $null
    }
    Write-Host '  ok     six hook events (PreToolUse only with -Enforce)'

    $statusLineOurs = $false
    if ($settings.Contains('statusLine') -and $settings['statusLine']) {
        $slCmd = [string]$settings['statusLine']['command']
        $statusLineOurs = $slCmd -match 'opus-tuner[/\\]scripts[/\\]statusline\.ps1'
    }
    if ($NoStatusLine) {
        if ($statusLineOurs) { $settings.Remove('statusLine') }
        Write-Host '  skip   status line (-NoStatusLine)'
    } elseif ($statusLineOurs -or -not $settings.Contains('statusLine') -or -not $settings['statusLine']) {
        $settings['statusLine'] = @{
            type    = 'command'
            command = (Get-StatusLineCommand)
            padding = 0
        }
        Write-Host '  ok     status line'
    } elseif ($Force) {
        $settings['statusLine'] = @{
            type    = 'command'
            command = (Get-StatusLineCommand)
            padding = 0
        }
        Write-Host '  ok     status line replaced (-Force; old value is in the backup)'
    } else {
        Write-Host '  keep   your existing status line (pass -Force to replace it)'
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host 'merged settings.json:' -ForegroundColor Yellow
        $settings | ConvertTo-Json -Depth 20
    } else {
        if (Test-Path -LiteralPath $settingsPath) {
            Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak-$stamp" -Force
            Write-Host "  ok     backup $settingsPath.bak-$stamp"
        }
        Write-JsonFile $settingsPath $settings
        Write-Host '  ok     settings.json written'
    }
}

# ---------- 3. CLAUDE.md ----------
Write-Host ''
Write-Host 'CLAUDE.md' -ForegroundColor Yellow
$begin = '<!-- opus-tuner:begin -->'
$end = '<!-- opus-tuner:end -->'
$block = @"
$begin
# token discipline
- Batch independent tool calls in one message; every turn re-reads all context.
- Grep before Read; bound reads with offset/limit.
- A ``[tuner] gear=X`` line means invoke ``/gear-X`` first.
- Send breadth (locating code, many files, suites) to a subagent; keep judgement local.
- At a task boundary, or 70% of the tier ceiling: ``/wrap``, then tell the user to ``/clear``. Never ``/compact`` at a boundary.
- Never trade verification for tokens.
$end
"@
# The here-string carries the checkout's line endings; normalise so a Linux
# install does not write CRLF into CLAUDE.md.
$block = $block -replace "`r`n", "`n"

if ($SkipClaudeMd) {
    Write-Host '  skip   (-SkipClaudeMd)'
} else {
    $existing = if (Test-Path -LiteralPath $claudeMdPath) { Get-Content -LiteralPath $claudeMdPath -Raw -Encoding UTF8 } else { '' }
    if ($existing -and $existing.Contains($begin)) {
        Write-Host '  keep   block already present (edit it yourself, or remove it and re-run)'
    } elseif ($DryRun) {
        Write-Host '  would  append the token-discipline block'
    } else {
        if (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null }
        $prefix = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { $existing.TrimEnd() + $nl + $nl }
        [System.IO.File]::WriteAllText($claudeMdPath, $prefix + ($block -replace "`n", $nl) + $nl, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host '  ok     token-discipline block appended'
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'dry run complete; nothing was written' -ForegroundColor Green
    exit 0
}
Write-Host 'done.' -ForegroundColor Green
Write-Host ''
Write-Host 'next:'
Write-Host '  1. restart Claude Code (or Developer: Reload Window in VS Code)'
if ($NoHooks) {
    Write-Host '     advisory mode: no hooks were registered, so there is nothing to reload'
} else {
    Write-Host '  2. run /hooks  -> expect UserPromptSubmit, PostToolUse, PostToolUseFailure, Stop, SessionStart, PreCompact'
}
Write-Host '  3. run /skills -> expect opus-tuner, claude-skill, gear-low, gear-medium, gear-xhigh, gear-max, wrap, profile'
$verify = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') 'selftest.ps1'
$doctor = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') 'doctor.ps1'
$exe = if ($OnWindows) { 'powershell -NoProfile' } else { 'pwsh -NoProfile' }
Write-Host "  4. verify:    $exe -File `"$verify`""
Write-Host "     diagnose:  $exe -File `"$doctor`""
Write-Host ''
exit 0
