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
    # Also register the optional PreToolUse Read guard (mode must be "guard").
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
$configPath = Join-Path $claudeDir 'tuner.config.json'
$backupDir = Join-Path (Join-Path $claudeDir 'state') 'opus-tuner-backups'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$nl = if ($OnWindows) { "`r`n" } else { "`n" }

# Each mode installs only the skills it can use. Every installed skill's
# description sits in the model's context on every request, so a skill that
# cannot help here is a standing cost:
#   - claude-skill is the hook-free fallback for Desktop and claude.ai; with
#     hooks the opus-tuner skill and the hooks already do its job;
#   - profile only changes what the hooks do, so it is useless without them.
$commonSkills = @('opus-tuner', 'gear-low', 'gear-medium', 'gear-xhigh', 'gear-max', 'wrap')
$skills = if ($NoHooks) { $commonSkills + @('claude-skill') } else { $commonSkills + @('profile') }
# What the other mode installs, and the text that proves a folder is ours.
$otherSkill = if ($NoHooks) { @{ name = 'profile'; marker = 'profile.ps1' } } else { @{ name = 'claude-skill'; marker = 'companion to opus-tuner' } }

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

# Switching modes, or upgrading from 0.5.0 and earlier (which installed both),
# leaves the other mode's skill behind. Move it to the backups when it is
# recognisably ours; a user's own skill with the same name is left alone.
$stale = Join-Path $skillsDir $otherSkill.name
$staleMd = Join-Path $stale 'SKILL.md'
if ((Test-Path -LiteralPath $staleMd) -and ([string](Get-Content -LiteralPath $staleMd -Raw -Encoding UTF8)).Contains($otherSkill.marker)) {
    if ($DryRun) {
        Write-Host "  would  move $($otherSkill.name) to backups (not used in this mode)"
    } else {
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
        Copy-Item -LiteralPath $stale -Destination (Join-Path $backupDir "$($otherSkill.name)-$stamp") -Recurse -Force
        Remove-Item -LiteralPath $stale -Recurse -Force
        Write-Host "  moved  $($otherSkill.name) to backups (not used in this mode)"
    }
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

# The user's settings, kept as an object so an upgrade can change one key and
# leave the order and everything else as written.
$configObject = $null
$configBroken = $false
if (Test-Path -LiteralPath $configPath) {
    try { $configObject = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $configBroken = $true }
    if (-not ($configObject -is [System.Management.Automation.PSCustomObject])) {
        $configObject = $null
        $configBroken = $true
    }
}
$configMode = ''
if ($configObject -and $configObject.PSObject.Properties['mode']) { $configMode = ([string]$configObject.mode).Trim().ToLowerInvariant() }

$settings = @{}
$hadOurHooks = $false
if (-not $NoHooks) {
    if (Test-Path -LiteralPath $settingsPath) {
        $settingsText = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        $hadOurHooks = $settingsText -match 'opus-tuner[/\\]scripts[/\\]'
        try {
            $settings = ConvertTo-Hashtable ($settingsText | ConvertFrom-Json)
        } catch {
            throw "settings.json is not valid JSON; fix it before installing: $settingsPath"
        }
        if (-not ($settings -is [System.Collections.IDictionary])) { $settings = @{} }
    }
    if (-not $settings.Contains('hooks')) { $settings['hooks'] = @{} }
    $hooks = $settings['hooks']

    # Someone already using the read guard keeps it through an upgrade: re-running
    # the installer without the original switch is not a choice to drop it.
    $readGuardInUse = @(@($hooks['PreToolUse']) | Where-Object {
        $_ -and ((@($_.hooks | ForEach-Object { [string]$_['command'] }) -join ' ') -match 'opus-tuner[/\\]scripts[/\\]pre-tool\.ps1')
    }).Count -gt 0
    $keepReadGuard = $readGuardInUse -and (@('guard', 'enforce') -contains $configMode)

    Set-OurHook $hooks 'UserPromptSubmit' (New-HookGroup 'route.ps1')
    Set-OurHook $hooks 'PostToolUse' (New-HookGroup 'post-tool.ps1' 'Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell|Read|Grep|Glob|WebFetch|mcp__.*' 10 -Async)
    Set-OurHook $hooks 'PostToolUseFailure' (New-HookGroup 'post-tool.ps1' '' 10 -Async)
    Set-OurHook $hooks 'Stop' (New-HookGroup 'stop.ps1')
    Set-OurHook $hooks 'SessionStart' (New-HookGroup 'session-start.ps1' 'startup|resume|clear|compact|fork' 15)
    Set-OurHook $hooks 'PreCompact' (New-HookGroup 'pre-compact.ps1' 'manual|auto')
    if ($Enforce -or $keepReadGuard) {
        Set-OurHook $hooks 'PreToolUse' (New-HookGroup 'pre-tool.ps1' 'Read')
        if (-not $Enforce) { Write-Host '  keep   the PreToolUse Read guard (already in use in guard mode)' }
    } else {
        Set-OurHook $hooks 'PreToolUse' $null
    }
    # An upgrade without -Force keeps the installed scripts, which may predate this
    # hook. Registering it anyway would run a missing file on every session exit.
    $sessionEndScript = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') 'session-end.ps1'
    if ($DryRun -or (Test-Path -LiteralPath $sessionEndScript)) {
        Set-OurHook $hooks 'SessionEnd' (New-HookGroup 'session-end.ps1' '' 5)
        Write-Host '  ok     seven hook events (PreToolUse only with -Enforce)'
    } else {
        Set-OurHook $hooks 'SessionEnd' $null
        Write-Host '  ok     six hook events (PreToolUse only with -Enforce)'
        Write-Host '  note   the installed scripts predate SessionEnd; run with -Force to upgrade them.' -ForegroundColor Yellow
    }

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

# ---------- 3. mode and interruptions ----------
# Before 0.7 the Stop prompt and the manual /compact block were on unless switched
# off. Now both have to be asked for. A setting someone chose keeps working, so it
# moves to guard; a default nobody chose changes, and the user is told so here.
if (-not $NoHooks) {
    Write-Host ''
    Write-Host 'mode and interruptions' -ForegroundColor Yellow
    $turnOn = "to turn them on, set `"mode`": `"guard`" with `"hardWrap`": true and/or `"blockManualCompact`": true in $configPath"
    $changedDefault = "before 0.7 the one-time Stop prompt and the first-/compact block were on by default. Now nothing interrupts a session unless asked; $turnOn"

    $notes = New-Object System.Collections.ArrayList
    $newMode = ''
    $addKeys = @()
    $isLegacyMode = @('', 'advise') -contains $configMode
    if ($configObject) {
        $named = @{}
        foreach ($k in @('hardWrap', 'blockManualCompact')) {
            if ($configObject.PSObject.Properties[$k]) { $named[$k] = $configObject.$k }
        }
        $chosen = @($named.Keys | Where-Object { $named[$_] -is [bool] -and $named[$_] })
        if ($configMode -eq 'enforce') {
            $newMode = 'guard'
            $addKeys = @(@('hardWrap', 'blockManualCompact') | Where-Object { -not $named.ContainsKey($_) })
            [void]$notes.Add('mode "enforce" is now called "guard". It no longer implies the interruptions, so any you had by default are now written out.')
        } elseif ($isLegacyMode -and $chosen.Count -gt 0) {
            $newMode = 'guard'
            [void]$notes.Add("you set $($chosen -join ' and ') to true, which now only works in guard mode, so mode is now guard.")
            foreach ($k in @('hardWrap', 'blockManualCompact')) {
                if (-not $named.ContainsKey($k)) { [void]$notes.Add("$k was on by default and is now off; set `"$k`": true to keep it.") }
            }
        }
    }

    $installedEnd = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') 'session-end.ps1'
    $scriptsCurrent = (Test-Path -LiteralPath $installedEnd) -or ($DryRun -and ($Force -or -not (Test-Path -LiteralPath (Join-Path $skillsDir 'opus-tuner'))))

    if ($configBroken) {
        Write-Host "  note   $configPath is not valid JSON, so it was left as it is. Hooks run on defaults until it is fixed." -ForegroundColor Yellow
    } elseif ($newMode -and -not $scriptsCurrent) {
        # Older scripts do not know the name guard, and would drop the read guard.
        Write-Host "  note   mode stays `"$configMode`" for now: the installed scripts predate guard mode. Run with -Force to upgrade both." -ForegroundColor Yellow
    } elseif ($newMode -and $DryRun) {
        Write-Host "  would  set mode to $newMode in $configPath"
        foreach ($k in $addKeys) { Write-Host "  would  set $k to true" }
        foreach ($n in $notes) { Write-Host "  note   $n" -ForegroundColor Yellow }
    } elseif ($newMode) {
        Copy-Item -LiteralPath $configPath -Destination "$configPath.bak-$stamp" -Force
        $configObject | Add-Member -NotePropertyName 'mode' -NotePropertyValue $newMode -Force
        foreach ($k in $addKeys) { $configObject | Add-Member -NotePropertyName $k -NotePropertyValue $true -Force }
        Write-JsonFile $configPath $configObject
        Write-Host "  ok     backup $configPath.bak-$stamp"
        Write-Host "  ok     mode is now $newMode"
        foreach ($k in $addKeys) { Write-Host "  ok     $k is now true" }
        foreach ($n in $notes) { Write-Host "  note   $n" -ForegroundColor Yellow }
    } elseif ($isLegacyMode -and ($configObject -or $hadOurHooks)) {
        Write-Host "  ok     mode assist"
        Write-Host "  note   $changedDefault" -ForegroundColor Yellow
    } elseif ($isLegacyMode) {
        Write-Host "  ok     mode assist (default): nothing interrupts a session; $turnOn"
    } else {
        Write-Host "  keep   mode $configMode"
    }
}

# ---------- 4. CLAUDE.md ----------
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
- When the user wants to continue in a fresh session, prepare and verify a handoff with ``/wrap``, then ask them to run ``/clear``.
- Never trade verification for tokens.
$end
"@
# The here-string carries the checkout's line endings; normalise so a Linux
# install does not write CRLF into CLAUDE.md.
$block = $block -replace "`r`n", "`n"

# Blocks earlier versions wrote. Only an exact match is ours to replace: anything
# else has been edited, and those edits belong to the user.
$knownBlocks = @(@(
@'
<!-- opus-tuner:begin -->
# token discipline
- Batch independent tool calls in one message; every turn re-reads all context.
- Grep before Read; bound reads with offset/limit.
- A `[tuner] gear=X` line means invoke `/gear-X` first.
- Send breadth (locating code, many files, suites) to a subagent; keep judgement local.
- At a task boundary, or 70% of the tier ceiling: `/wrap`, then tell the user to `/clear`. Never `/compact` at a boundary.
- Never trade verification for tokens.
<!-- opus-tuner:end -->
'@
) | ForEach-Object { $_ -replace "`r`n", "`n" })

if ($SkipClaudeMd) {
    Write-Host '  skip   (-SkipClaudeMd)'
} else {
    $existing = if (Test-Path -LiteralPath $claudeMdPath) { Get-Content -LiteralPath $claudeMdPath -Raw -Encoding UTF8 } else { '' }
    if ($existing -and $existing.Contains($begin)) {
        $found = [regex]::Match($existing, '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end))
        $foundText = $found.Value -replace "`r`n", "`n"
        if ($foundText -ceq $block) {
            Write-Host '  keep   block already current'
        } elseif ($found.Success -and $knownBlocks -ccontains $foundText) {
            if ($DryRun) {
                Write-Host '  would  update the token-discipline block'
            } else {
                $eol = if ($found.Value.Contains("`r`n")) { "`r`n" } else { "`n" }
                Copy-Item -LiteralPath $claudeMdPath -Destination "$claudeMdPath.bak-$stamp" -Force
                $updated = $existing.Substring(0, $found.Index) + ($block -replace "`n", $eol) + $existing.Substring($found.Index + $found.Length)
                [System.IO.File]::WriteAllText($claudeMdPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
                Write-Host "  ok     backup $claudeMdPath.bak-$stamp"
                Write-Host '  ok     token-discipline block updated'
            }
        } else {
            Write-Host '  keep   block looks edited, so it was left as written' -ForegroundColor Yellow
            Write-Host '  note   current wording for the handoff line: When the user wants to continue in a fresh session, prepare and verify a handoff with /wrap, then ask them to run /clear.' -ForegroundColor Yellow
        }
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
    Write-Host '  2. run /hooks  -> expect UserPromptSubmit, PostToolUse, PostToolUseFailure, Stop, SessionStart, SessionEnd, PreCompact'
}
Write-Host "  3. run /skills -> expect $($skills -join ', ')"
$verify = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') 'selftest.ps1'
$doctor = Join-Path (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') 'doctor.ps1'
$exe = if ($OnWindows) { 'powershell -NoProfile' } else { 'pwsh -NoProfile' }
Write-Host "  4. verify:    $exe -File `"$verify`""
Write-Host "     diagnose:  $exe -File `"$doctor`""
Write-Host ''
exit 0
