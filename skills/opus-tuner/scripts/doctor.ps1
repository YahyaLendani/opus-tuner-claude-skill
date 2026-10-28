# Install health check. Answers "why is nothing firing?" without making the user
# read the settings file by hand.
#
#   powershell -NoProfile -File doctor.ps1
#   powershell -NoProfile -File doctor.ps1 -Json
#   powershell -NoProfile -File doctor.ps1 -Root C:\temp\sandbox
#
# Exit code 0 means everything it checks is healthy, 1 means something needs
# attention. It is read-only apart from a probe file in the state directory, and
# it never touches a transcript.

param(
    [switch]$Json,
    # Check a different config dir than the one in use.
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

if ($Root) {
    $script:TunerRoot = $Root
    $script:TunerState = Join-Path (Join-Path $Root 'state') 'tuner'
    $script:TunerConfig = Join-Path $Root 'tuner.config.json'
}

$settingsPath = Join-Path $script:TunerRoot 'settings.json'
$skillsDir = Join-Path $script:TunerRoot 'skills'
$checks = New-Object System.Collections.ArrayList
$fail = 0

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    [void]$script:checks.Add([pscustomobject]@{ check = $Name; ok = $Ok; detail = $Detail })
    if (-not $Ok) { $script:fail++ }
}

function Get-HookPaths {
    param($Settings, [string]$Event)
    $out = New-Object System.Collections.ArrayList
    if (-not $Settings -or -not $Settings.PSObject.Properties['hooks']) { return , $out }
    $hooks = $Settings.hooks
    if (-not $hooks.PSObject.Properties[$Event]) { return , $out }
    foreach ($group in @($hooks.$Event)) {
        foreach ($h in @($group.hooks)) {
            $cmd = [string]$h.command
            if ($cmd -notmatch 'opus-tuner[/\\]scripts[/\\]') { continue }
            $m = [regex]::Match($cmd, '"([^"]+)"')
            if ($m.Success) { [void]$out.Add($m.Groups[1].Value) }
        }
    }
    return , $out
}

$expected = [ordered]@{
    UserPromptSubmit   = 'route.ps1'
    PostToolUse        = 'post-tool.ps1'
    PostToolUseFailure = 'post-tool.ps1'
    Stop               = 'stop.ps1'
    SessionStart       = 'session-start.ps1'
    PreCompact         = 'pre-compact.ps1'
}

# ---------- settings and wiring ----------
$settings = $null
if (-not (Test-Path -LiteralPath $settingsPath)) {
    Add-Check 'settings.json exists' $false $settingsPath
} else {
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Check 'settings.json parses' $true
    } catch {
        Add-Check 'settings.json parses' $false $_.Exception.Message
    }
}

if ($settings) {
    foreach ($ev in $expected.Keys) {
        $paths = Get-HookPaths $settings $ev
        Add-Check "$ev registered" (@($paths).Count -ge 1) "found $(@($paths).Count)"
        if (@($paths).Count -ge 1) {
            $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath $_) })
            Add-Check "$ev script exists" ($missing.Count -eq 0) ($missing -join '; ')
        }
    }

    $pre = Get-HookPaths $settings 'PreToolUse'
    if (@($pre).Count -gt 0) {
        $missing = @($pre | Where-Object { -not (Test-Path -LiteralPath $_) })
        Add-Check 'PreToolUse (optional) script exists' ($missing.Count -eq 0) ($missing -join '; ')
    }

    $sl = $settings.statusLine
    if ($sl -and ([string]$sl.command -match 'opus-tuner[/\\]scripts[/\\]statusline\.ps1')) {
        $m = [regex]::Match([string]$sl.command, '"([^"]+)"')
        Add-Check 'status line script exists' ($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value))
    }

    if ($settings.modelSettings -and $settings.modelSettings.'claude-opus-5-5') {
        $lvl = [string]$settings.modelSettings.'claude-opus-5-5'.effortLevel
        Add-Check 'Opus 5.5 effort level valid' (@('low', 'medium', 'high', 'xhigh') -contains $lvl) $lvl
    }
}

# ---------- config ----------
if (Test-Path -LiteralPath $script:TunerConfig) {
    $issue = Get-TunerConfigIssue
    Add-Check 'tuner.config.json parses' ([string]::IsNullOrEmpty($issue)) $issue
}

$cfg = Get-TunerConfig
$routine = [int64]$cfg['routineTokens']
$deep = [int64]$cfg['deepTokens']
Add-Check 'routineTokens < deepTokens' ($routine -lt $deep) "$routine / $deep"

if ($settings -and $settings.autoCompactWindow) {
    Add-Check 'deepTokens < autoCompactWindow' ($deep -lt [int64]$settings.autoCompactWindow) "$deep / $($settings.autoCompactWindow)"
}

Add-Check 'mode is a known value' (@('advise', 'enforce', 'off') -contains [string]$cfg['mode']) ([string]$cfg['mode'])

# POSIX hooks name pwsh explicitly, so a missing pwsh is the most likely reason
# nothing fires on macOS or Linux.
if (-not $script:OnWindows) {
    Add-Check 'pwsh on PATH' ([bool](Get-Command pwsh -ErrorAction SilentlyContinue)) 'hooks run with pwsh'
}

# ---------- skills ----------
foreach ($s in @('opus-tuner', 'claude-skill', 'gear-low', 'gear-medium', 'gear-xhigh', 'gear-max', 'wrap')) {
    $md = Join-Path (Join-Path $skillsDir $s) 'SKILL.md'
    $ok = Test-Path -LiteralPath $md
    $detail = if ($ok) { '' } else { "missing $md" }
    Add-Check "skill $s installed" $ok $detail
    if ($ok) {
        $head = Get-Content -LiteralPath $md -TotalCount 5 -Encoding UTF8
        $nameLine = @($head | Where-Object { $_ -match '^name:\s*' }) | Select-Object -First 1
        $declared = if ($nameLine) { ($nameLine -replace '^name:\s*', '').Trim() } else { '' }
        Add-Check "skill $s declares its name" ($declared -eq $s) "name: '$declared'"
    }
}

# ---------- scripts parse ----------
$scripts = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $skillsDir 'opus-tuner') 'scripts') -Filter '*.ps1' -ErrorAction SilentlyContinue)
if ($scripts.Count -eq 0) {
    Add-Check 'scripts present' $false 'no .ps1 files found'
} else {
    $bad = New-Object System.Collections.ArrayList
    foreach ($f in $scripts) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        if ($errs) { [void]$bad.Add("$($f.Name): $($errs[0].Message)") }
    }
    Add-Check "all $($scripts.Count) scripts parse" ($bad.Count -eq 0) ($bad -join '; ')
}

# ---------- state is writable ----------
try {
    if (-not (Test-Path -LiteralPath $script:TunerState)) {
        New-Item -ItemType Directory -Force -Path $script:TunerState | Out-Null
    }
    $probe = Join-Path $script:TunerState ('.doctor-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [System.IO.File]::WriteAllText($probe, 'ok', (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $probe -Force
    Add-Check 'state directory is writable' $true
} catch {
    Add-Check 'state directory is writable' $false $_.Exception.Message
}

# ---------- report ----------
if ($Json) {
    Write-HookJson @{ ok = ($fail -eq 0); failed = $fail; checks = @($checks) }
    if ($fail -eq 0) { exit 0 } else { exit 1 }
}

$section = ''
foreach ($c in $checks) {
    $group = switch -Regex ($c.check) {
        '^(settings|UserPromptSubmit|PostToolUse|PostToolUseFailure|Stop|SessionStart|PreCompact|PreToolUse|status|Opus)' { 'wiring'; break }
        '^(routineTokens|deepTokens|mode|tuner)' { 'configuration'; break }
        '^skill' { 'skills'; break }
        '^all ' { 'scripts'; break }
        default { 'runtime' }
    }
    if ($group -ne $section) {
        $section = $group
        ''
        Write-Host $group -ForegroundColor Yellow
    }
    if ($c.ok) {
        Write-Host ("  ok    {0}" -f $c.check) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}  {1}" -f $c.check, $c.detail) -ForegroundColor Red
    }
}

''
if ($fail -eq 0) {
    Write-Host "healthy: $($checks.Count) checks passed" -ForegroundColor Green
    Write-Host ''
    exit 0
}
Write-Host "$fail of $($checks.Count) checks failed" -ForegroundColor Red
Write-Host 'Re-run install.ps1 -Force to repair the wiring; see docs/troubleshooting.md.'
Write-Host ''
exit 1
