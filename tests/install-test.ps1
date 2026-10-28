# Installer integration test. Runs install.ps1 and uninstall.ps1 against a
# throwaway CLAUDE_CONFIG_DIR, seeded with hooks, a status line and CLAUDE.md
# content that belong to a hypothetical user. Asserts that:
#
#   - our hooks are added and the user's are kept
#   - a second install is idempotent (no duplicate entries)
#   - a foreign status line is preserved unless -Force is passed
#   - uninstall removes only our entries and our CLAUDE.md block
#   - -DryRun writes nothing
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/install-test.ps1

$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$install = Join-Path $repo 'install.ps1'
$uninstall = Join-Path $repo 'uninstall.ps1'
$sandbox = Join-Path $env:TEMP ('opus-tuner-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$pass = 0
$fail = 0
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

function New-Sandbox {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'skills') | Out-Null
    $settings = @{
        model      = 'opus'
        statusLine = @{ type = 'command'; command = 'echo mine' }
        hooks      = @{
            Stop        = @(@{ hooks = @(@{ type = 'command'; shell = 'powershell'; command = '& "C:/tools/mine.ps1"'; timeout = 5 }) })
            PostToolUse = @(@{ matcher = 'Read'; hooks = @(@{ type = 'command'; shell = 'powershell'; command = '& "C:/tools/audit.ps1"'; timeout = 5 }) })
        }
    }
    $json = $settings | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText((Join-Path $Path 'settings.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $Path 'CLAUDE.md'), "# my rules`r`nkeep me`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Settings {
    param([string]$Path)
    return (Get-Content -LiteralPath (Join-Path $Path 'settings.json') -Raw | ConvertFrom-Json)
}

function Count-Our {
    param($Settings, [string]$Event)
    return @(@($Settings.hooks.$Event) | Where-Object {
        (@($_.hooks | ForEach-Object { [string]$_.command }) -join ' ') -match 'opus-tuner/scripts/'
    }).Count
}

function Count-User {
    param($Settings, [string]$Event, [string]$Needle)
    return @(@($Settings.hooks.$Event) | Where-Object {
        (@($_.hooks | ForEach-Object { [string]$_.command }) -join ' ') -match [regex]::Escape($Needle)
    }).Count
}

$oldConfigDir = $env:CLAUDE_CONFIG_DIR
try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    New-Sandbox $sandbox
    $env:CLAUDE_CONFIG_DIR = $sandbox

    Write-Host ''
    Write-Host 'installer test' -ForegroundColor Cyan
    Write-Host "sandbox: $sandbox"

    # ---------- first install ----------
    Write-Host ''
    Write-Host 'first install (foreign status line)' -ForegroundColor Yellow
    & $install | Out-Null
    Check 'install exits 0' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

    $s = Read-Settings $sandbox
    foreach ($ev in @('UserPromptSubmit', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionStart')) {
        Check "$ev has exactly one opus-tuner hook" ((Count-Our $s $ev) -eq 1) "count $(Count-Our $s $ev)"
    }
    Check 'PreToolUse not registered without -Enforce' ((Count-Our $s 'PreToolUse') -eq 0)
    Check "user's Stop hook kept" ((Count-User $s 'Stop' 'mine.ps1') -eq 1)
    Check "user's PostToolUse hook kept" ((Count-User $s 'PostToolUse' 'audit.ps1') -eq 1)
    Check 'foreign status line preserved' ($s.statusLine.command -eq 'echo mine') $s.statusLine.command
    Check 'PostToolUse hook is async' ([bool]$s.hooks.PostToolUse[0].hooks[0].async -or [bool]$s.hooks.PostToolUse[1].hooks[0].async)
    Check 'settings backup created' (@(Get-ChildItem $sandbox -Filter 'settings.json.bak-*').Count -ge 1)

    $skills = @(Get-ChildItem (Join-Path $sandbox 'skills') -Directory)
    Check 'six skills installed' ($skills.Count -eq 6) "count $($skills.Count)"
    $md = Get-Content (Join-Path $sandbox 'CLAUDE.md') -Raw
    Check 'CLAUDE.md keeps user content' ($md -match 'keep me')
    Check 'CLAUDE.md gains the block' ($md -match '<!-- opus-tuner:begin -->')

    # ---------- idempotency ----------
    Write-Host ''
    Write-Host 'second install (idempotent)' -ForegroundColor Yellow
    & $install | Out-Null
    $s = Read-Settings $sandbox
    Check 'no duplicate UserPromptSubmit hook' ((Count-Our $s 'UserPromptSubmit') -eq 1)
    Check 'no duplicate Stop hook' ((Count-Our $s 'Stop') -eq 1)
    Check 'CLAUDE.md block not duplicated' (([regex]::Matches((Get-Content (Join-Path $sandbox 'CLAUDE.md') -Raw), 'opus-tuner:begin')).Count -eq 1)

    # ---------- force ----------
    Write-Host ''
    Write-Host 'install -Force' -ForegroundColor Yellow
    & $install -Force | Out-Null
    $s = Read-Settings $sandbox
    Check '-Force replaces the status line' ($s.statusLine.command -match 'statusline\.ps1') $s.statusLine.command
    Check '-Force still keeps user hooks' ((Count-User $s 'Stop' 'mine.ps1') -eq 1)
    Check 'replaced skill folder backed up outside skills/' (@(Get-ChildItem (Join-Path $sandbox 'state\opus-tuner-backups') -Directory -ErrorAction SilentlyContinue).Count -ge 1)
    Check 'no backup folders inside skills/' (@(Get-ChildItem (Join-Path $sandbox 'skills') -Directory -Filter '*.bak-*').Count -eq 0)

    # ---------- uninstall ----------
    Write-Host ''
    Write-Host 'uninstall' -ForegroundColor Yellow
    & $uninstall | Out-Null
    $s = Read-Settings $sandbox
    foreach ($ev in @('UserPromptSubmit', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionStart')) {
        Check "$ev has no opus-tuner hook" ((Count-Our $s $ev) -eq 0) "count $(Count-Our $s $ev)"
    }
    Check "user's Stop hook survives uninstall" ((Count-User $s 'Stop' 'mine.ps1') -eq 1)
    Check 'our status line removed' (-not $s.statusLine)
    Check 'all six skill folders removed' (@(Get-ChildItem (Join-Path $sandbox 'skills') -Directory -ErrorAction SilentlyContinue).Count -eq 0) "left: $(@(Get-ChildItem (Join-Path $sandbox 'skills') -Directory).Name -join ',')"
    $md = Get-Content (Join-Path $sandbox 'CLAUDE.md') -Raw
    Check 'CLAUDE.md keeps user content after uninstall' ($md -match 'keep me')
    Check 'CLAUDE.md block removed' (-not ($md -match 'opus-tuner:begin'))

    # ---------- enforce ----------
    Write-Host ''
    Write-Host 'install -Enforce' -ForegroundColor Yellow
    & $install -Enforce | Out-Null
    $s = Read-Settings $sandbox
    Check 'PreToolUse registered with -Enforce' ((Count-Our $s 'PreToolUse') -eq 1)
    Check 'PreToolUse matcher is Read' ($s.hooks.PreToolUse[0].matcher -eq 'Read') $s.hooks.PreToolUse[0].matcher
    & $uninstall | Out-Null
    $s = Read-Settings $sandbox
    Check 'uninstall removes PreToolUse' ((Count-Our $s 'PreToolUse') -eq 0)

    # ---------- dry run ----------
    Write-Host ''
    Write-Host 'dry run on a fresh directory' -ForegroundColor Yellow
    $fresh = Join-Path $sandbox 'fresh'
    New-Item -ItemType Directory -Force -Path $fresh | Out-Null
    $env:CLAUDE_CONFIG_DIR = $fresh
    & $install -DryRun | Out-Null
    Check 'dry run writes no settings' (-not (Test-Path (Join-Path $fresh 'settings.json')))
    Check 'dry run writes no skills' (-not (Test-Path (Join-Path $fresh 'skills\opus-tuner')))
    Check 'dry run writes no CLAUDE.md' (-not (Test-Path (Join-Path $fresh 'CLAUDE.md')))
} finally {
    $env:CLAUDE_CONFIG_DIR = $oldConfigDir
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host "$pass passed, 0 failed" -ForegroundColor Green
    exit 0
}
Write-Host "$pass passed, $fail failed" -ForegroundColor Red
exit 1
