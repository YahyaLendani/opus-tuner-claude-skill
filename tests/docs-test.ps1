# What the instructions and docs promise has to match what the scripts do. These
# strings were all once written down as fact: a fresh session always starts at
# about 500 tokens, a handoff is always cheaper than compaction, the model can run
# or refuse native commands, and the Stop hook makes the ceiling a limit.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/docs-test.ps1
#   pwsh -NoProfile -File tests/docs-test.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$null = New-TestSandbox 'docs'

$root = Split-Path -Parent $PSScriptRoot
$rootPrefix = $root.TrimEnd('\', '/')
function Read-Doc { param([string]$Relative) return [System.IO.File]::ReadAllText((Join-Path $root $Relative)) }
function Get-Relative { param([string]$Path) return $Path.Substring($rootPrefix.Length + 1) -replace '\\', '/' }

$docs = New-Object System.Collections.ArrayList
foreach ($f in @('README.md', 'SECURITY.md')) { [void]$docs.Add((Join-Path $root $f)) }
foreach ($dir in @('docs', 'skills')) {
    Get-ChildItem -LiteralPath (Join-Path $root $dir) -Recurse -File -Filter '*.md' | ForEach-Object { [void]$docs.Add($_.FullName) }
}
$instructions = @($docs | Where-Object {
    $r = Get-Relative $_
    $r -like '*/SKILL.md' -or $r -like '*/references/*'
})

# Lines matching any of these describe the old behaviour on purpose.
$historyLine = '(?i)older|legacy|before 0\.7|previous version|old name'

function Find-Lines {
    param([string[]]$Files, [string]$Pattern)
    $hits = New-Object System.Collections.ArrayList
    foreach ($file in $Files) {
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines($file)) {
            $n++
            if ($line -match $Pattern -and $line -notmatch $historyLine) {
                [void]$hits.Add("$(Get-Relative $file):$n")
            }
        }
    }
    return ,$hits
}

Write-Host 'docs tests' -ForegroundColor Cyan

Write-Section 'unsupported claims are gone'
$banned = [ordered]@{
    'a fresh session at a fixed token count' = '(?i)(~|about |roughly |approximately )500([- ]tokens?)?\b'
    'handoffs always beating compaction'     = '(?i)cheaper than (a )?`?/?compact|handoffs? (is|are) (always )?cheaper|handoff\.? plus `?/clear`? beats'
    'the ceiling as a gate'                  = '(?i)\bgate\b.{0,20}\b(suggestion|wall)\b|\bceiling\b.{0,30}\bgate\b|\bgate\b.{0,20}\bceiling\b'
    'the name hard wrap'                     = '(?i)\bhard wrap\b'
    'compaction as a thing to avoid at all'  = '(?i)failure mode this bundle|exists to (avoid|replace)|thing this bundle exists'
    'savings stated as fact'                 = '(?i)\bautomatic savings\b|\bpays for itself\b|\bgears? pay\b|\d+x cheaper'
}
foreach ($name in $banned.Keys) {
    $hits = Find-Lines $docs $banned[$name]
    Check "no doc claims $name" ($hits.Count -eq 0) ($hits -join ', ')
}

Write-Section 'names and paths match the code'
$stale = [ordered]@{
    'old mode values in examples'  = '"mode":\s*"(advise|enforce)"|`(advise|enforce)` \(default\)|in `enforce` mode|enforce mode'
    'the shared handoff file'      = '\.claude[/\\]handoff\.md'
    'removed functions'            = 'Write-State|Get-NewestTranscript'
    'six hooks'                    = '(?i)\bsix (hooks|hook events|wiring checks)\b|all six events'
}
foreach ($name in $stale.Keys) {
    $hits = Find-Lines $docs $stale[$name]
    Check "no doc mentions $name" ($hits.Count -eq 0) ($hits -join ', ')
}

Write-Section 'instructions stay instructions'
$modelFacing = [ordered]@{
    'telling the model what native commands to run or avoid' = '(?i)(do not|never|don''t) `?/compact|\brun `?/compact\b|`?/wrap`? \+ `?/clear|tell the user to `?/clear'
    'dollar figures'                                         = '\$\d'
    'one measured session as a rule'                         = '98\.7|78%'
    'promises about what a session costs next'               = '(?i)get expensive|gives a fresh|costs? less|is cheaper'
}
foreach ($name in $modelFacing.Keys) {
    $hits = Find-Lines $instructions $modelFacing[$name]
    Check "no skill instruction has $name" ($hits.Count -eq 0) ($hits -join ', ')
}
$skill = Read-Doc 'skills/opus-tuner/SKILL.md'
Check 'the skill says how to continue in a fresh session' ($skill -match 'When the user wants to continue in a fresh session, prepare and verify a handoff\. Ask them to run `/clear` afterward\.')
Check 'the skill keeps runtime hooks separate' ($skill -match 'Runtime hooks separately control any configured compaction interruption\.')
Check 'the skill does not narrate hook decisions' ($skill -notmatch '(?i)stop hook \*?\*?blocks|refuses to end')
$portable = Read-Doc 'skills/claude-skill/SKILL.md'
Check 'the portable skill does not compare a handoff with compaction' ($portable -notmatch '(?i)than compaction')

Write-Section 'interruptions are documented exactly'
$cfgDoc = Read-Doc 'docs/configuration.md'
foreach ($mode in @('off', 'monitor', 'assist', 'guard')) {
    Check "configuration lists mode $mode" ($cfgDoc -match "(?m)^\| ``$mode``")
}
Check 'configuration names the old mode values' ($cfgDoc -match 'advise' -and $cfgDoc -match 'enforce')
$m = [regex]::Match($cfgDoc, '(?s)## What can interrupt a session(.*?)(\n## |\z)')
Check 'configuration has a section on what can interrupt a session' $m.Success
$section = $m.Groups[1].Value
foreach ($need in @('`Stop`', '`PreCompact`', '`PreToolUse`', '`hardWrap`', '`blockManualCompact`', '-Enforce', 'Automatic compaction', '`/clear`')) {
    Check "that section covers $need" ($section.Contains($need))
}
Check 'that section says the Stop hook is a one-time prompt, not a limit' ($section -match '(?i)one-time' -and $section -match '(?i)not a (context )?limit')
Check 'that section says how to disable each one' ($section -match '(?i)how to (turn|switch) (it |them )?off|disable')
Check 'that section says the default interrupts nothing' ($section -match '(?i)by default')

$readme = Read-Doc 'README.md'
foreach ($mode in @('monitor', 'assist', 'guard')) {
    Check "the readme names mode $mode" ($readme -match "(?i)\b$mode\b")
}
Check 'the readme links the interruptions section' ($readme -match 'configuration\.md#what-can-interrupt-a-session')
Check 'the readme says why a default changed for upgraders' ($readme -match '(?i)upgrad')
Check 'the readme lists SessionEnd' ($readme -match 'SessionEnd')

Complete-TestRun 'docs tests'
