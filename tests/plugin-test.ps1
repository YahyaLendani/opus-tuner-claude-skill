# The plugin install: what /plugin install puts on disk has to do the same work
# as install.ps1, with nothing to run by hand.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/plugin-test.ps1
#   pwsh -NoProfile -File tests/plugin-test.ps1
#
# Claude Code runs a plugin hook by substituting ${CLAUDE_PLUGIN_ROOT} into the
# command, exporting the same variable, and handing the command to bash (Git Bash
# on Windows). Invoke-PluginHook does exactly that, so these tests exercise the
# command strings in hooks/hooks.json, not a copy of them.

param([string]$Interpreter = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Interpreter = Get-TestInterpreter $Interpreter
$null = New-TestSandbox 'plugin'
# For Get-GitBash, the same lookup the doctor uses.
. (Join-Path $script:ScriptDir '_common.ps1')
$ErrorActionPreference = 'Stop'

Write-Host "plugin tests  (interpreter: $($script:Interpreter))" -ForegroundColor Cyan

$proj = Join-Path $script:Sandbox 'project'
New-Item -ItemType Directory -Force -Path $proj | Out-Null
$repo = $script:RepoRoot
$pluginJsonPath = Join-Path (Join-Path $repo '.claude-plugin') 'plugin.json'
$marketJsonPath = Join-Path (Join-Path $repo '.claude-plugin') 'marketplace.json'
$hooksJsonPath = Join-Path (Join-Path $repo 'hooks') 'hooks.json'
$runSh = Join-Path (Join-Path $repo 'hooks') 'run.sh'
$version = (Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $repo 'skills') 'opus-tuner') 'VERSION') -Raw).Trim()

function Read-JsonFile {
    param([string]$Path)
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---------- manifests ----------
Write-Section 'manifests'
$plugin = Read-JsonFile $pluginJsonPath
Check 'plugin.json parses' ($null -ne $plugin)
Check 'plugin is named opus-tuner' ($plugin -and $plugin.name -eq 'opus-tuner') "$($plugin.name)"
Check 'plugin.json version matches VERSION' ($plugin -and $plugin.version -eq $version) "plugin $($plugin.version), VERSION $version"
$market = Read-JsonFile $marketJsonPath
Check 'marketplace.json parses' ($null -ne $market)
$entry = if ($market) { @($market.plugins) | Where-Object { $_.name -eq 'opus-tuner' } | Select-Object -First 1 } else { $null }
Check 'marketplace lists opus-tuner from this repository' ($entry -and [string]$entry.source -eq './') "$($entry | ConvertTo-Json -Compress)"

# Only the skills meant for a hooked install: the plugin scans every folder in
# skills/, so the hook-free claude-skill must live somewhere else.
$pluginSkills = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object { $_.Name } | Sort-Object)
$wantSkills = @('gear-low', 'gear-max', 'gear-medium', 'gear-xhigh', 'opus-tuner', 'profile', 'wrap')
Check 'plugin ships the hooked skill set' (($pluginSkills -join ',') -eq ($wantSkills -join ',')) ($pluginSkills -join ',')
Check 'portable claude-skill sits outside skills/' (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $repo 'portable') 'claude-skill') 'SKILL.md'))

# Plugin skills run from the plugin cache, so a doc that names ~/.claude/skills
# sends the model to a folder that does not exist.
$stale = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills') -Recurse -Filter '*.md' | Where-Object { $_.Name -ne 'README.md' } | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '\.claude[/\\]+skills|USERPROFILE|CLAUDE_CONFIG_DIR'
} | ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
Check 'skill docs locate scripts relative to the skill' ($stale.Count -eq 0) ($stale -join ', ')

# ---------- hooks.json against the installer ----------
Write-Section 'hooks.json'
$hooksDoc = Read-JsonFile $hooksJsonPath
Check 'hooks.json parses with a hooks object' ($hooksDoc -and $hooksDoc.PSObject.Properties['hooks'])

# What install.ps1 registers is the reference: same events, matchers, timeouts.
$instDir = Join-Path $script:Sandbox 'installer'
New-Item -ItemType Directory -Force -Path $instDir | Out-Null
$prevConfig = $env:CLAUDE_CONFIG_DIR
$env:CLAUDE_CONFIG_DIR = $instDir
try {
    $prefix = @(Get-ExePrefix)
    $null = & $script:Interpreter @prefix -File (Join-Path $repo 'install.ps1') -Force 2>&1
} finally { $env:CLAUDE_CONFIG_DIR = $prevConfig }
$instSettings = Read-JsonFile (Join-Path $instDir 'settings.json')
Check 'installer reference settings written' ($null -ne $instSettings)

$instEvents = @($instSettings.hooks.PSObject.Properties | Where-Object {
    (@(@($_.Value) | ForEach-Object { @($_.hooks) | ForEach-Object { [string]$_.command } }) -join ' ') -match 'opus-tuner[/\\]scripts[/\\]'
} | ForEach-Object { $_.Name } | Sort-Object)
$plugEvents = @($hooksDoc.hooks.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
Check 'same hook events as the installer' (($instEvents -join ',') -eq ($plugEvents -join ',')) "installer $($instEvents -join ','); plugin $($plugEvents -join ',')"
Check 'no PreToolUse read guard (installer -Enforce only)' ($plugEvents -notcontains 'PreToolUse')

foreach ($ev in $plugEvents) {
    $pg = @($hooksDoc.hooks.$ev)[0]
    $ph = @($pg.hooks)[0]
    $ig = @($instSettings.hooks.$ev) | Where-Object { (@($_.hooks | ForEach-Object { [string]$_.command }) -join ' ') -match 'opus-tuner[/\\]scripts[/\\]' } | Select-Object -First 1
    $ih = if ($ig) { @($ig.hooks)[0] } else { $null }
    $m = [regex]::Match([string]$ph.command, '^bash "\$\{CLAUDE_PLUGIN_ROOT\}/hooks/run\.sh" ([a-z-]+)$')
    Check "$ev runs through hooks/run.sh with shell bash" ($m.Success -and $ph.shell -eq 'bash' -and $ph.type -eq 'command') "$($ph | ConvertTo-Json -Compress)"
    if (-not $m.Success -or -not $ih) { continue }
    $name = $m.Groups[1].Value
    Check "$ev script exists" (Test-Path -LiteralPath (Join-Path $script:ScriptDir "$name.ps1")) $name
    Check "$ev runs the installer's script" ([string]$ih.command -match ([regex]::Escape("$name.ps1") + '"?$')) "$name vs $($ih.command)"
    Check "$ev matcher, timeout and async match the installer" (
        ([string]$pg.matcher -eq [string]$ig.matcher) -and ([int]$ph.timeout -eq [int]$ih.timeout) -and ([bool]$ph.async -eq [bool]$ih.async)
    ) "plugin $([string]$pg.matcher)/$($ph.timeout)/$([bool]$ph.async); installer $([string]$ig.matcher)/$($ih.timeout)/$([bool]$ih.async)"
}

# ---------- run.sh ----------
Write-Section 'run.sh'
$runBytes = [System.IO.File]::ReadAllBytes($runSh)
$runText = [System.Text.Encoding]::UTF8.GetString($runBytes)
Check 'run.sh starts with a bash shebang' ($runText.StartsWith("#!/usr/bin/env bash`n"))
Check 'run.sh has LF line endings only' (-not ($runBytes -contains 13))
$gitMode = ''
try { $gitMode = [string](& git -C $repo ls-files -s -- hooks/run.sh 2>$null) } catch { }
if ($gitMode) { Check 'run.sh is executable in git' ($gitMode.StartsWith('100755')) $gitMode }

# ---------- hooks through the plugin command ----------
Write-Section 'hooks run through the plugin command'
$bash = Get-GitBash
Check 'bash found for plugin hooks' ([bool]$bash) 'on Windows this needs Git for Windows'

function Invoke-PluginHook {
    param([string]$Event, [hashtable]$Payload, [string]$Root = $repo, [hashtable]$Env = @{})
    $h = @(@($hooksDoc.hooks.$Event)[0].hooks)[0]
    $rootFwd = $Root -replace '\\', '/'
    $cmd = ([string]$h.command).Replace('${CLAUDE_PLUGIN_ROOT}', $rootFwd)
    $saved = @{}
    $Env['CLAUDE_PLUGIN_ROOT'] = $Root
    foreach ($k in $Env.Keys) { $saved[$k] = [System.Environment]::GetEnvironmentVariable($k); [System.Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress
        $out = $json | & $bash -c $cmd 2>&1
        $code = $LASTEXITCODE
        return @{ text = ((@($out | ForEach-Object { [string]$_ }) -join "`n").Trim()); code = $code }
    } finally {
        $ErrorActionPreference = $eap
        foreach ($k in $saved.Keys) { [System.Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

function Test-EmptyOrJson {
    param([string]$Text)
    if (-not $Text) { return $true }
    try { $null = $Text | ConvertFrom-Json; return $true } catch { return $false }
}

$claudeMd = Join-Path $script:ClaudeDir 'CLAUDE.md'
$settingsFile = Join-Path $script:ClaudeDir 'settings.json'

if ($bash) {
    $cases = @(
        @{ event = 'SessionStart'; payload = @{ session_id = 'plug-start'; cwd = $proj; hook_event_name = 'SessionStart'; source = 'startup' } },
        @{ event = 'UserPromptSubmit'; payload = @{ session_id = 'plug-route'; cwd = $proj; hook_event_name = 'UserPromptSubmit'; prompt = 'refactor the auth module'; transcript_path = '' } },
        @{ event = 'PostToolUse'; payload = @{ session_id = 'plug-post'; cwd = $proj; hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = @{ file_path = (Join-Path $proj 'a.ts') } } },
        @{ event = 'PostToolUseFailure'; payload = @{ session_id = 'plug-fail'; cwd = $proj; hook_event_name = 'PostToolUseFailure'; tool_name = 'Bash'; tool_input = @{ command = 'npm test' } } },
        @{ event = 'Stop'; payload = @{ session_id = 'plug-stop'; cwd = $proj; hook_event_name = 'Stop'; stop_hook_active = $false; transcript_path = '' } },
        @{ event = 'PreCompact'; payload = @{ session_id = 'plug-compact'; cwd = $proj; hook_event_name = 'PreCompact'; trigger = 'auto'; transcript_path = '' } },
        @{ event = 'SessionEnd'; payload = @{ session_id = 'plug-end'; cwd = $proj; hook_event_name = 'SessionEnd'; reason = 'other' } }
    )
    foreach ($c in $cases) {
        $r = Invoke-PluginHook $c.event $c.payload
        Check "$($c.event) exits 0" ($r.code -eq 0) "exit $($r.code): $($r.text)"
        Check "$($c.event) prints empty or JSON" (Test-EmptyOrJson $r.text) $r.text
    }
    Check 'the plugin hooks wrote state' (Test-Path -LiteralPath (Join-Path $script:StateDir 'plug-route.json')) (@(Get-ChildItem -LiteralPath $script:StateDir -Name) -join ', ')

    # ---------- the rules that install.ps1 writes to CLAUDE.md ----------
    Write-Section 'token-discipline rules without CLAUDE.md'
    $start = @{ session_id = 'plug-rules'; cwd = $proj; hook_event_name = 'SessionStart'; source = 'startup' }
    $r = Invoke-PluginHook 'SessionStart' $start
    Check 'startup injects the rules when CLAUDE.md lacks them' ($r.text -match 'token discipline \(opus-tuner\)') $r.text
    Check 'the rules name the namespaced skills' ($r.text -match 'opus-tuner:wrap' -and $r.text -match 'opus-tuner:gear-X') $r.text
    foreach ($src in @('clear', 'compact')) {
        $r = Invoke-PluginHook 'SessionStart' @{ session_id = "plug-rules-$src"; cwd = $proj; hook_event_name = 'SessionStart'; source = $src }
        Check "$src injects the rules too" ($r.text -match 'token discipline \(opus-tuner\)') $r.text
    }
    foreach ($src in @('resume', 'fork')) {
        $r = Invoke-PluginHook 'SessionStart' @{ session_id = "plug-rules-$src"; cwd = $proj; hook_event_name = 'SessionStart'; source = $src }
        Check "$src does not inject them again" ($r.text -notmatch 'token discipline') $r.text
    }

    [System.IO.File]::WriteAllText($claudeMd, "# mine`n<!-- opus-tuner:begin -->`n# token discipline`n<!-- opus-tuner:end -->`n", $script:Utf8)
    $r = Invoke-PluginHook 'SessionStart' $start
    Check 'no injection when CLAUDE.md already has the block' ($r.text -notmatch 'token discipline') $r.text
    Remove-Item -LiteralPath $claudeMd -Force

    Set-TestConfig '{"mode":"monitor"}'
    $r = Invoke-PluginHook 'SessionStart' $start
    Check 'monitor mode adds nothing to the context' ($r.text -notmatch 'additionalContext') $r.text
    Set-TestConfig '{}'

    $r = Invoke-Hook 'session-start.ps1' $start
    Check 'a direct run (installer hooks) does not inject them' ($r.text -notmatch 'token discipline') $r.text

    # ---------- plugin and installer both present ----------
    Write-Section 'plugin and installer hooks both present'
    Copy-Item -LiteralPath (Join-Path $instDir 'settings.json') -Destination $settingsFile -Force
    $r = Invoke-PluginHook 'SessionStart' $start
    Check 'plugin copy stands down when installer hooks are registered' ($r.code -eq 0 -and -not $r.text) $r.text
    $r = Invoke-PluginHook 'UserPromptSubmit' @{ session_id = 'plug-dup'; cwd = $proj; hook_event_name = 'UserPromptSubmit'; prompt = 'refactor the auth module'; transcript_path = '' }
    Check 'stood-down hook writes no state' ($r.code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $script:StateDir 'plug-dup.json'))) $r.text
    $saved = $env:CLAUDE_PLUGIN_ROOT
    $env:CLAUDE_PLUGIN_ROOT = $repo
    $tr = New-TestTranscript -Project $proj -Sid 'plug-ctx' -Ctx 42000
    try { $r = Invoke-Script 'ctx.ps1' @('-Transcript', $tr) } finally { $env:CLAUDE_PLUGIN_ROOT = $saved }
    Check 'scripts run by hand from a plugin skill still answer' ($r.code -eq 0 -and $r.text -match '42') $r.text
    Remove-Item -LiteralPath $settingsFile -Force

    # ---------- no pwsh on macOS and Linux ----------
    if (-not $script:OnWin) {
        Write-Section 'no pwsh'
        $noPwsh = @{ OPUS_TUNER_PWSH = '/nonexistent/pwsh' }
        $r = Invoke-PluginHook 'SessionStart' $start -Env $noPwsh
        $msg = $null
        try { $msg = $r.text | ConvertFrom-Json } catch { }
        Check 'SessionStart says pwsh is missing, once' ($r.code -eq 0 -and $msg -and ([string]$msg.systemMessage -match 'PowerShell 7')) $r.text
        $r = Invoke-PluginHook 'UserPromptSubmit' @{ session_id = 'plug-nopwsh'; cwd = $proj; hook_event_name = 'UserPromptSubmit'; prompt = 'hi'; transcript_path = '' } -Env $noPwsh
        Check 'other hooks fail open and silent' ($r.code -eq 0 -and -not $r.text) $r.text
    }
}

# ---------- doctor from the plugin layout ----------
Write-Section 'doctor in a plugin install'
# A copy laid out the way the plugin cache holds it.
$plugCopy = Join-Path $script:Sandbox 'cache\opus-tuner\0.0.0'
New-Item -ItemType Directory -Force -Path $plugCopy | Out-Null
foreach ($d in @('.claude-plugin', 'hooks', 'skills')) { Copy-Item -LiteralPath (Join-Path $repo $d) -Destination (Join-Path $plugCopy $d) -Recurse -Force }
$doctor = Join-Path (Join-Path (Join-Path (Join-Path $plugCopy 'skills') 'opus-tuner') 'scripts') 'doctor.ps1'
$prefix = @(Get-ExePrefix)

function Invoke-Doctor {
    param([string[]]$Arguments)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = '' | & $script:Interpreter @prefix -File $doctor @Arguments 2>&1
        return @{ text = ((@($out | ForEach-Object { [string]$_ }) -join "`n").Trim()); code = $LASTEXITCODE }
    } finally { $ErrorActionPreference = $eap }
}

$r = Invoke-Doctor @('-Json')
$doc = $null
try { $doc = $r.text | ConvertFrom-Json } catch { }
Check 'doctor -Json parses' ($null -ne $doc) $r.text
if ($doc) {
    $failed = @($doc.checks | Where-Object { -not $_.ok } | ForEach-Object { "$($_.check): $($_.detail)" })
    Check 'doctor reports a plugin install healthy' ($doc.ok -and $r.code -eq 0) ($failed -join '; ')
    Check 'doctor treats the plugin as hooked, not advisory' (-not $doc.advisory)
    Check 'doctor checks the plugin hooks.json' (@($doc.checks | Where-Object { $_.check -eq 'plugin hooks.json parses' -and $_.ok }).Count -eq 1)
    Check 'doctor checks each plugin hook' (@($doc.checks | Where-Object { $_.check -match '^\w+ registered \(plugin\)$' -and $_.ok }).Count -eq 7)
}
Check 'doctor writes nothing into the plugin folder' (-not (Test-Path -LiteralPath (Join-Path $plugCopy 'state')) -and -not (Test-Path -LiteralPath (Join-Path $plugCopy 'tuner.config.json')))

if ($bash) {
    $r = Invoke-Doctor @('-Replay')
    Check 'doctor -Replay runs every plugin hook' ($r.code -eq 0 -and $r.text -match 'replay SessionStart re-seeds the brief') $r.text
}

Copy-Item -LiteralPath (Join-Path $instDir 'settings.json') -Destination $settingsFile -Force
$r = Invoke-Doctor @('-Json')
$doc = $null
try { $doc = $r.text | ConvertFrom-Json } catch { }
Check 'doctor notes when the installer hooks are registered too' ($doc -and @($doc.checks | Where-Object { $_.PSObject.Properties['note'] -and $_.note -and $_.check -match 'installer' }).Count -ge 1) $r.text
Remove-Item -LiteralPath $settingsFile -Force

Complete-TestRun 'plugin tests'
