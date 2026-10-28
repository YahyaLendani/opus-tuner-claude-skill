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
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('opus-tuner-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# Run child scripts with the interpreter that is running this test, so the
# Windows 5.1 job exercises 5.1 and the POSIX jobs exercise pwsh.
$OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$Interpreter = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
$ExePrefix = @('-NoProfile')
if ($OnWindows) { $ExePrefix += @('-ExecutionPolicy', 'Bypass') }

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
    foreach ($ev in @('UserPromptSubmit', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionStart', 'PreCompact')) {
        Check "$ev has exactly one opus-tuner hook" ((Count-Our $s $ev) -eq 1) "count $(Count-Our $s $ev)"
    }
    Check 'PreToolUse not registered without -Enforce' ((Count-Our $s 'PreToolUse') -eq 0)
    Check "user's Stop hook kept" ((Count-User $s 'Stop' 'mine.ps1') -eq 1)
    Check "user's PostToolUse hook kept" ((Count-User $s 'PostToolUse' 'audit.ps1') -eq 1)
    Check 'foreign status line preserved' ($s.statusLine.command -eq 'echo mine') $s.statusLine.command
    Check 'PostToolUse hook is async' ([bool]$s.hooks.PostToolUse[0].hooks[0].async -or [bool]$s.hooks.PostToolUse[1].hooks[0].async)
    Check 'settings backup created' (@(Get-ChildItem $sandbox -Filter 'settings.json.bak-*').Count -ge 1)

    # The hook command is the one line that differs by platform. Asserting it
    # here is what catches a POSIX port that still points at PowerShell 5.1.
    # Stop[0] is the user's hook, so find ours by its path.
    $ourStop = @(@($s.hooks.Stop) | Where-Object {
        (@($_.hooks | ForEach-Object { [string]$_.command }) -join ' ') -match 'opus-tuner'
    })[0].hooks[0]
    if ($OnWindows) {
        Check 'hooks run through PowerShell' ($ourStop.command -match '^& "' -and $ourStop.shell -eq 'powershell') $ourStop.command
    } else {
        Check 'hooks run through pwsh' ($ourStop.command -match '^pwsh -NoProfile -File "' -and $ourStop.shell -eq 'bash') $ourStop.command
    }

    $skills = @(Get-ChildItem (Join-Path $sandbox 'skills') -Directory)
    Check 'seven skills installed' ($skills.Count -eq 7) "count $($skills.Count)"
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
    Check 'replaced skill folder backed up outside skills/' (@(Get-ChildItem (Join-Path (Join-Path $sandbox 'state') 'opus-tuner-backups') -Directory -ErrorAction SilentlyContinue).Count -ge 1)
    Check 'no backup folders inside skills/' (@(Get-ChildItem (Join-Path $sandbox 'skills') -Directory -Filter '*.bak-*').Count -eq 0)

    # ---------- doctor ----------
    Write-Host ''
    Write-Host 'doctor' -ForegroundColor Yellow
    $doctor = Join-Path (Join-Path (Join-Path (Join-Path $sandbox 'skills') 'opus-tuner') 'scripts') 'doctor.ps1'
    & $Interpreter @ExePrefix -File $doctor | Out-Null
    Check 'doctor reports a healthy install' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

    # The version has to survive the copy: SECURITY.md asks reporters for it, and
    # a bug report without it is a round trip.
    $installedVersion = Join-Path (Join-Path (Join-Path $sandbox 'skills') 'opus-tuner') 'VERSION'
    Check 'VERSION file installed with the skill' (Test-Path -LiteralPath $installedVersion)
    $expectedVersion = (Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills') 'opus-tuner') 'VERSION') -Raw).Trim()
    $versionOut = (& $Interpreter @ExePrefix -File $doctor 2>&1) -join "`n"
    Check 'doctor reports the installed version' ($versionOut -match [regex]::Escape("opus-tuner $expectedVersion")) $versionOut

    # -Replay executes the command strings from settings.json, which is the only
    # check that catches a quoting error or a shell that cannot start the
    # interpreter. Registration plus a script that parses does not prove either.
    $replayOut = (& $Interpreter @ExePrefix -File $doctor -Replay 2>&1) -join "`n"
    Check 'doctor -Replay passes on a healthy install' ($LASTEXITCODE -eq 0) $replayOut

    $settingsFile = Join-Path $sandbox 'settings.json'
    $rawSettings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8
    [System.IO.File]::WriteAllText($settingsFile, ($rawSettings -replace 'stop\.ps1', 'stop-missing.ps1'), (New-Object System.Text.UTF8Encoding($false)))
    $brokenOut = (& $Interpreter @ExePrefix -File $doctor -Replay 2>&1) -join "`n"
    Check 'doctor -Replay catches a broken hook command' ($LASTEXITCODE -eq 1 -and $brokenOut -match 'replay Stop') $brokenOut
    [System.IO.File]::WriteAllText($settingsFile, $rawSettings, (New-Object System.Text.UTF8Encoding($false)))

    # Auto-advisory must fire only at zero hooks. A partial install is broken,
    # not advisory, and must still fail rather than quietly pass.
    $obj = $rawSettings | ConvertFrom-Json
    $obj.hooks.PSObject.Properties.Remove('PreCompact')
    [System.IO.File]::WriteAllText($settingsFile, ($obj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $partialOut = (& $Interpreter @ExePrefix -File $doctor 2>&1) -join "`n"
    Check 'doctor still fails on a partial wiring' ($LASTEXITCODE -eq 1 -and $partialOut -match 'PreCompact registered') $partialOut
    [System.IO.File]::WriteAllText($settingsFile, $rawSettings, (New-Object System.Text.UTF8Encoding($false)))

    # The effort check used to be keyed to 'claude-opus-5-5', so a future model
    # name made it a silent no-op. It must validate whatever model is configured.
    $future = $rawSettings | ConvertFrom-Json
    $future | Add-Member -NotePropertyName modelSettings -Force -NotePropertyValue ([pscustomobject]@{
        'claude-opus-6' = [pscustomobject]@{ effortLevel = 'extreme' }
    })
    [System.IO.File]::WriteAllText($settingsFile, ($future | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $futureOut = (& $Interpreter @ExePrefix -File $doctor 2>&1) -join "`n"
    Check 'doctor validates effort for a model it has never heard of' ($LASTEXITCODE -eq 1 -and $futureOut -match 'model effort levels valid' -and $futureOut -match 'claude-opus-6=extreme') $futureOut
    [System.IO.File]::WriteAllText($settingsFile, $rawSettings, (New-Object System.Text.UTF8Encoding($false)))

    $badCfg = Join-Path $sandbox 'tuner.config.json'
    [System.IO.File]::WriteAllText($badCfg, '{ "routineTokens": 150000,', (New-Object System.Text.UTF8Encoding($false)))
    $docOut = (& $Interpreter @ExePrefix -File $doctor 2>&1) -join "`n"
    Check 'doctor catches a malformed config' ($LASTEXITCODE -eq 1) "exit $LASTEXITCODE"
    Check 'doctor names the bad config' ($docOut -match 'tuner\.config\.json') $docOut
    Remove-Item -LiteralPath $badCfg -Force

    # ---------- uninstall ----------
    Write-Host ''
    Write-Host 'uninstall' -ForegroundColor Yellow
    & $uninstall | Out-Null
    $s = Read-Settings $sandbox
    foreach ($ev in @('UserPromptSubmit', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionStart', 'PreCompact')) {
        Check "$ev has no opus-tuner hook" ((Count-Our $s $ev) -eq 0) "count $(Count-Our $s $ev)"
    }
    Check "user's Stop hook survives uninstall" ((Count-User $s 'Stop' 'mine.ps1') -eq 1)
    Check 'our status line removed' (-not $s.statusLine)
    Check 'all seven skill folders removed' (@(Get-ChildItem (Join-Path $sandbox 'skills') -Directory -ErrorAction SilentlyContinue).Count -eq 0) "left: $(@(Get-ChildItem (Join-Path $sandbox 'skills') -Directory).Name -join ',')"
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
    Check 'dry run writes no skills' (-not (Test-Path (Join-Path (Join-Path $fresh 'skills') 'opus-tuner')))
    Check 'dry run writes no CLAUDE.md' (-not (Test-Path (Join-Path $fresh 'CLAUDE.md')))

    # ---------- advisory mode ----------
    Write-Host ''
    Write-Host 'install -NoHooks (advisory mode)' -ForegroundColor Yellow
    $advisory = Join-Path $sandbox 'advisory'
    New-Item -ItemType Directory -Force -Path $advisory | Out-Null
    $env:CLAUDE_CONFIG_DIR = $advisory
    & $install -NoHooks | Out-Null
    Check 'advisory mode exits 0' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    Check 'advisory mode writes no settings.json' (-not (Test-Path (Join-Path $advisory 'settings.json')))
    Check 'advisory mode still installs skills' (Test-Path (Join-Path (Join-Path $advisory 'skills') 'opus-tuner'))
    Check 'advisory mode still writes CLAUDE.md' ((Get-Content (Join-Path $advisory 'CLAUDE.md') -Raw) -match 'opus-tuner:begin')

    # A skills-only install is a legitimate configuration, not a broken one. The
    # doctor must say so and exit 0 instead of failing six wiring checks.
    $advDoctor = Join-Path (Join-Path (Join-Path (Join-Path $advisory 'skills') 'opus-tuner') 'scripts') 'doctor.ps1'
    $advOut = (& $Interpreter @ExePrefix -File $advDoctor 2>&1) -join "`n"
    Check 'doctor reports an advisory install as healthy' ($LASTEXITCODE -eq 0 -and $advOut -match 'advisory install') $advOut
    Check 'advisory doctor creates no state directory' (-not (Test-Path (Join-Path $advisory 'state')))
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
