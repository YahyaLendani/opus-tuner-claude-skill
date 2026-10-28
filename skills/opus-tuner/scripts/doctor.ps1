# Install health check. Answers "why is nothing firing?" without making the user
# read the settings file by hand.
#
#   powershell -NoProfile -File doctor.ps1
#   powershell -NoProfile -File doctor.ps1 -Json
#   powershell -NoProfile -File doctor.ps1 -Root C:\temp\sandbox
#   powershell -NoProfile -File doctor.ps1 -Replay
#   powershell -NoProfile -File doctor.ps1 -SkillsOnly
#
# Exit code 0 means everything it checks is healthy, 1 means something needs
# attention. It is read-only apart from a probe file in the state directory, and
# it never touches a transcript.
#
# -Replay goes one step further than registration: it executes each registered
# command exactly as written, in a throwaway config dir, and asserts exit 0 and
# empty-or-valid-JSON output. Registration plus a script that parses is not the
# same as a hook that runs: a quoting error in the command string, or a shell
# that cannot find the interpreter, fails only at invocation time.
#
# -SkillsOnly checks the skills, config and scripts without requiring hooks. It
# is implied automatically when settings.json registers no opus-tuner hooks, so
# a copy that is deliberately advisory (a vendored skills-only install) reports
# healthy instead of failing six wiring checks it never asked for.
#
# Run from a vendored copy (<root>/skills/opus-tuner/scripts) it checks that
# copy, not the user-wide ~/.claude. The installed copy derives ~/.claude, so
# the default is unchanged there. -Root and CLAUDE_CONFIG_DIR still win.

param(
    [switch]$Json,
    # Check a different config dir than the one in use.
    [string]$Root = '',
    # Execute the registered commands, not just check that they exist.
    [switch]$Replay,
    # Do not require or validate hook registration.
    [switch]$SkillsOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

if ($Root) {
    $script:TunerRoot = $Root
    $script:TunerState = Join-Path (Join-Path $Root 'state') 'tuner'
    $script:TunerConfig = Join-Path $Root 'tuner.config.json'
} elseif (-not $env:CLAUDE_CONFIG_DIR) {
    # A vendored copy lives at <root>/skills/opus-tuner/scripts, so the tree the
    # doctor belongs to is three levels up. The installed copy derives ~/.claude,
    # which is what _common.ps1 already chose, so this is a no-op there.
    $derivedRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    if ($derivedRoot -and $derivedRoot -ne $script:TunerRoot -and
        (Test-Path -LiteralPath (Join-Path (Join-Path $derivedRoot 'skills') 'opus-tuner'))) {
        $script:TunerRoot = $derivedRoot
        if (-not $env:OPUS_TUNER_STATE) { $script:TunerState = Join-Path (Join-Path $derivedRoot 'state') 'tuner' }
        if (-not $env:OPUS_TUNER_CONFIG) { $script:TunerConfig = Join-Path $derivedRoot 'tuner.config.json' }
    }
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

# A check that does not apply here. Recorded, printed, never counted as a
# failure: an advisory install is a legitimate configuration, not a broken one.
function Add-Skip {
    param([string]$Name, [string]$Detail = '')
    [void]$script:checks.Add([pscustomobject]@{ check = $Name; ok = $true; skipped = $true; detail = $Detail })
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

# Run one registered command the way Claude Code would: the command string from
# settings.json, through the shell declared next to it, with a realistic payload
# on stdin. The config dir is redirected so state and the decision log land in a
# sandbox rather than the live install.
function Invoke-RegisteredHook {
    param($Settings, [string]$Event, [string]$Payload, [string]$ConfigDir)

    $group = @($Settings.hooks.$Event) | Where-Object {
        (@($_.hooks | ForEach-Object { [string]$_.command }) -join ' ') -match 'opus-tuner[/\\]scripts[/\\]'
    } | Select-Object -First 1
    if (-not $group) { return @{ ran = $false; detail = 'no opus-tuner hook registered' } }

    $h = @($group.hooks)[0]
    $cmd = [string]$h.command
    $shell = [string]$h.shell
    $errFile = Join-Path $ConfigDir ("replay-$Event.err")

    $prev = $env:CLAUDE_CONFIG_DIR
    $env:CLAUDE_CONFIG_DIR = $ConfigDir
    try {
        if ($script:OnWindows -and $shell -ne 'bash') {
            $out = $Payload | & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2> $errFile
        } elseif ($script:OnWindows) {
            $out = $Payload | & bash -c $cmd 2> $errFile
        } else {
            $out = $Payload | & sh -c $cmd 2> $errFile
        }
        $code = $LASTEXITCODE
        $err = if (Test-Path -LiteralPath $errFile) { (Get-Content -LiteralPath $errFile -Raw) } else { '' }
        return @{ ran = $true; code = $code; text = (@($out) -join "`n"); err = [string]$err }
    } catch {
        return @{ ran = $false; detail = $_.Exception.Message }
    } finally {
        $env:CLAUDE_CONFIG_DIR = $prev
    }
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
$settingsExists = Test-Path -LiteralPath $settingsPath
if ($settingsExists) {
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Check 'settings.json parses' $true
    } catch {
        Add-Check 'settings.json parses' $false $_.Exception.Message
    }
}

# What is actually registered decides what "healthy" means here. A skills-only
# copy has no hooks by design, and six red wiring checks for that would teach
# people to ignore the doctor.
$hookCount = 0
if ($settings) {
    foreach ($ev in $expected.Keys) {
        if (@(Get-HookPaths $settings $ev).Count -gt 0) { $hookCount++ }
    }
}
$advisory = $SkillsOnly -or ($hookCount -eq 0)

if (-not $settingsExists) {
    if ($advisory) {
        Add-Skip 'settings.json exists' 'advisory install: nothing to register'
    } else {
        Add-Check 'settings.json exists' $false $settingsPath
    }
}

if ($settings) {
    foreach ($ev in $expected.Keys) {
        $paths = Get-HookPaths $settings $ev
        if ($SkillsOnly) {
            Add-Skip "$ev registered" 'skills-only: hooks not checked'
            continue
        }
        if ($advisory) {
            Add-Skip "$ev registered" 'advisory install: no hooks registered'
            continue
        }
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

# ---------- replay ----------
if ($Replay) {
    if ($SkillsOnly -or $advisory) {
        $why = if ($SkillsOnly) { 'skills-only: hooks not checked' } else { 'advisory install: no hook commands to execute' }
        Add-Skip 'replay' $why
    } elseif (-not $settings) {
        Add-Check 'replay: settings.json available' $false 'install first'
    } else {
        $replayRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('opus-tuner-replay-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $replayProject = Join-Path $replayRoot 'project'
        $replayClaude = Join-Path $replayProject '.claude'
        New-Item -ItemType Directory -Force -Path $replayClaude | Out-Null
        # A brief makes SessionStart emit real JSON, so the replay exercises the
        # output shape rather than only the empty-output path.
        [System.IO.File]::WriteAllText((Join-Path $replayClaude 'handoff.md'),
            "# Handoff - replay`n`n## Next step`n- replay the wiring`n",
            (New-Object System.Text.UTF8Encoding($false)))

        $cases = @(
            @{ event = 'SessionStart'; payload = @{ session_id = 'replay-start'; cwd = $replayProject; hook_event_name = 'SessionStart'; source = 'clear' } },
            @{ event = 'UserPromptSubmit'; payload = @{ session_id = 'replay-route'; cwd = $replayProject; hook_event_name = 'UserPromptSubmit'; prompt = 'refactor the auth module, then fix the failing test suite'; transcript_path = '' } },
            @{ event = 'PostToolUse'; payload = @{ session_id = 'replay-post'; cwd = $replayProject; hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = @{ file_path = (Join-Path $replayProject 'a.ts') } } },
            @{ event = 'PostToolUseFailure'; payload = @{ session_id = 'replay-post-fail'; cwd = $replayProject; hook_event_name = 'PostToolUseFailure'; tool_name = 'Bash'; tool_input = @{ command = 'npm test' } } },
            @{ event = 'Stop'; payload = @{ session_id = 'replay-stop'; cwd = $replayProject; hook_event_name = 'Stop'; stop_hook_active = $false; transcript_path = '' } },
            @{ event = 'PreCompact'; payload = @{ session_id = 'replay-compact'; cwd = $replayProject; hook_event_name = 'PreCompact'; trigger = 'auto'; transcript_path = '' } }
        )

        foreach ($c in $cases) {
            $name = "replay $($c.event)"
            # Not $json: PowerShell is case-insensitive, and this script's -Json
            # parameter is a [switch], so assigning a string to it fails.
            $payloadJson = $c['payload'] | ConvertTo-Json -Depth 8 -Compress
            $r = Invoke-RegisteredHook $settings $c.event $payloadJson $replayRoot
            if (-not $r['ran']) {
                Add-Check $name $false ([string]$r['detail'])
                continue
            }
            Add-Check "$name exits 0" ([int]$r['code'] -eq 0) ("exit {0} {1}" -f $r['code'], ([string]$r['err']).Trim())

            $text = ([string]$r['text']).Trim()
            $valid = $true
            $why = ''
            if ($text) {
                try { $null = $text | ConvertFrom-Json } catch {
                    $valid = $false
                    $why = 'not JSON: ' + $text.Substring(0, [Math]::Min(100, $text.Length))
                }
            }
            Add-Check "$name emits empty or JSON" $valid $why
            if ($c.event -eq 'SessionStart') {
                Add-Check 'replay SessionStart re-seeds the brief' ($text -match 'additionalContext') $text
            }
        }

        Remove-Item -Recurse -Force $replayRoot -ErrorAction SilentlyContinue
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
if ($advisory) {
    $why = if ($SkillsOnly) { 'skills-only: hooks not checked' } else { 'advisory install: no hooks, no state written' }
    Add-Skip 'state directory is writable' $why
} else {
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
}

# ---------- report ----------
$skipped = @($checks | Where-Object { $_.PSObject.Properties['skipped'] -and $_.skipped }).Count

if ($Json) {
    Write-HookJson @{ ok = ($fail -eq 0); failed = $fail; advisory = $advisory; skipped = $skipped; checks = @($checks) }
    if ($fail -eq 0) { exit 0 } else { exit 1 }
}

$section = ''
foreach ($c in $checks) {
    $group = switch -Regex ($c.check) {
        '^replay' { 'replay'; break }
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
    if ($c.PSObject.Properties['skipped'] -and $c.skipped) {
        Write-Host ("  skip  {0}  {1}" -f $c.check, $c.detail) -ForegroundColor DarkGray
    } elseif ($c.ok) {
        Write-Host ("  ok    {0}" -f $c.check) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}  {1}" -f $c.check, $c.detail) -ForegroundColor Red
    }
}

''
if ($fail -eq 0) {
    $passed = $checks.Count - $skipped
    $suffix = if ($skipped -gt 0) { ", $skipped skipped" } else { '' }
    Write-Host "healthy: $passed checks passed$suffix" -ForegroundColor Green
    if ($hookCount -eq 0) {
        Write-Host ''
        Write-Host 'advisory install: no opus-tuner hooks are registered, so the ceilings,' -ForegroundColor Yellow
        Write-Host 'the /compact refusal and the handoff nudges are off by design. The skills' -ForegroundColor Yellow
        Write-Host 'still work. Run install.ps1 -Force to add the hooks.'
    }
    Write-Host ''
    exit 0
}
Write-Host "$fail of $($checks.Count) checks failed" -ForegroundColor Red
Write-Host 'Re-run install.ps1 -Force to repair the wiring; see docs/troubleshooting.md.'
Write-Host ''
exit 1
