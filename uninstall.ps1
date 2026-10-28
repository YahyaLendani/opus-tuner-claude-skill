# opus-tuner uninstaller.
#
# Removes only what this bundle added: its hook entries, its status line, its
# CLAUDE.md block, and its skill folders. Hooks, status lines and CLAUDE.md
# content that you wrote yourself are left alone.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -KeepSkills
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -DryRun
#
# -Purge also deletes tuner.config.json and state/tuner (session state and the
# decision log). Project handoff briefs live in <project>/.claude/handoff.md and
# are never touched.

[CmdletBinding()]
param(
    [switch]$KeepSkills,
    [switch]$Purge,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$skillsDir = Join-Path $claudeDir 'skills'
$settingsPath = Join-Path $claudeDir 'settings.json'
$claudeMdPath = Join-Path $claudeDir 'CLAUDE.md'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ours = 'opus-tuner[/\\]scripts[/\\]'
$skills = @('opus-tuner', 'gear-low', 'gear-medium', 'gear-xhigh', 'gear-max', 'wrap')

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

Write-Host ''
Write-Host "opus-tuner uninstall <- $claudeDir" -ForegroundColor Cyan
if ($DryRun) { Write-Host 'dry run: nothing will be removed' -ForegroundColor Yellow }

$changed = $false

# ---------- settings.json ----------
if (Test-Path -LiteralPath $settingsPath) {
    $settings = ConvertTo-Hashtable (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('hooks') -and $settings['hooks'] -is [System.Collections.IDictionary]) {
        $hooks = $settings['hooks']
        foreach ($ev in @($hooks.Keys)) {
            $kept = @(@($hooks[$ev]) | Where-Object {
                $cmds = @($_.hooks | ForEach-Object { [string]$_['command'] }) -join ' '
                $cmds -notmatch $ours
            })
            if (@($kept).Count -ne @($hooks[$ev]).Count) {
                $hooks[$ev] = $kept
                $changed = $true
                Write-Host "  ok     removed hooks from $ev"
            }
        }
    }
    if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('statusLine') -and $settings['statusLine']) {
        if ([string]$settings['statusLine']['command'] -match 'opus-tuner[/\\]scripts[/\\]statusline\.ps1') {
            $settings.Remove('statusLine')
            $changed = $true
            Write-Host '  ok     removed status line'
        }
    }
    if ($changed) {
        if ($DryRun) {
            Write-Host '  would  write settings.json'
        } else {
            Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak-$stamp" -Force
            $json = $settings | ConvertTo-Json -Depth 20
            $tmp = "$settingsPath.tmp"
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination $settingsPath -Force
            Write-Host "  ok     settings.json written (backup: settings.json.bak-$stamp)"
        }
    } else {
        Write-Host '  keep   settings.json had no opus-tuner entries'
    }
}

# ---------- CLAUDE.md ----------
if (Test-Path -LiteralPath $claudeMdPath) {
    $text = Get-Content -LiteralPath $claudeMdPath -Raw -Encoding UTF8
    if ($text -match '<!-- opus-tuner:begin -->') {
        $clean = [regex]::Replace($text, '(?s)<!-- opus-tuner:begin -->.*?<!-- opus-tuner:end -->\r?\n?', '')
        $clean = $clean.TrimEnd()
        if ($DryRun) {
            Write-Host '  would  remove the token-discipline block from CLAUDE.md'
        } elseif ([string]::IsNullOrWhiteSpace($clean)) {
            Remove-Item -LiteralPath $claudeMdPath -Force
            Write-Host '  ok     CLAUDE.md removed (it contained only the block)'
        } else {
            [System.IO.File]::WriteAllText($claudeMdPath, $clean + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-Host '  ok     token-discipline block removed from CLAUDE.md'
        }
    }
}

# ---------- skills ----------
if ($KeepSkills) {
    Write-Host '  keep   skill folders (-KeepSkills)'
} else {
    foreach ($s in $skills) {
        $dst = Join-Path $skillsDir $s
        if (Test-Path -LiteralPath $dst) {
            if ($DryRun) {
                Write-Host "  would  remove $s"
            } else {
                Remove-Item -LiteralPath $dst -Recurse -Force
                Write-Host "  ok     removed $s"
            }
        }
    }
}

# ---------- optional data ----------
if ($Purge) {
    foreach ($p in @((Join-Path $claudeDir 'tuner.config.json'), (Join-Path $claudeDir 'state\tuner'))) {
        if (Test-Path -LiteralPath $p) {
            if ($DryRun) {
                Write-Host "  would  remove $p"
            } else {
                Remove-Item -LiteralPath $p -Recurse -Force
                Write-Host "  ok     removed $p"
            }
        }
    }
}

Write-Host ''
if ($DryRun) { Write-Host 'dry run complete; nothing was removed' -ForegroundColor Green }
else {
    Write-Host 'done. Restart Claude Code (or Developer: Reload Window) to drop the hooks.' -ForegroundColor Green
}
Write-Host ''
exit 0
