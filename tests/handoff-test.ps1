# Handoffs must be attributed to the session that wrote them, must not collide,
# and must never carry a credential into a later session.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/handoff-test.ps1
#   pwsh -NoProfile -File tests/handoff-test.ps1

param([string]$Interpreter = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Interpreter = Get-TestInterpreter $Interpreter
$null = New-TestSandbox 'handoff'

$projA = Join-Path $script:Sandbox 'project-a'
$projB = Join-Path $script:Sandbox 'project-b'
New-Item -ItemType Directory -Force -Path $projA, $projB | Out-Null

Write-Host "handoff tests  (interpreter: $($script:Interpreter))" -ForegroundColor Cyan

# ---------- identity ----------
Write-Section 'the session must be identified, never guessed'

$sidA = 'aaaaaaaa-0000-4000-8000-000000000001'
$sidB = 'bbbbbbbb-0000-4000-8000-000000000002'
$sidA2 = 'aaaaaaaa-0000-4000-8000-000000000003'
$trA = New-TestTranscript -Project $projA -Sid $sidA -Files @((Join-Path $projA 'only-in-a.ts')) -Commands @('npm test') -Ctx 111000
$trA2 = New-TestTranscript -Project $projA -Sid $sidA2 -Files @((Join-Path $projA 'only-in-a2.ts')) -Commands @('cargo build') -Ctx 122000
$trB = New-TestTranscript -Project $projB -Sid $sidB -Files @((Join-Path $projB 'only-in-b.ts')) -Commands @('go test') -Ctx 133000
# The trap the old code fell into: the newest transcript on disk belongs to
# somebody else's project.
$decoySid = 'dddddddd-0000-4000-8000-00000000000d'
$decoyProject = Join-Path $script:Sandbox 'project-decoy'
New-Item -ItemType Directory -Force -Path $decoyProject | Out-Null
$decoy = New-TestTranscript -Project $decoyProject -Sid $decoySid -Files @((Join-Path $decoyProject 'decoy-file.ts')) -Commands @('decoy-command --flag') -Ctx 999000
(Get-Item -LiteralPath $decoy).LastWriteTime = (Get-Date).AddMinutes(5)

$r = Invoke-Script 'brief.ps1' @('-Project', $projA)
Check 'no session id: fails' ($r.code -ne 0) "exit $($r.code): $($r.text)"
Check 'no session id: says why' ($r.text -match 'session') $r.text
Check 'no session id: does not read the newest transcript' ($r.text -notmatch 'decoy') $r.text
Check 'no session id: writes nothing' (@(Get-ChildItem -LiteralPath $script:StateDir -Recurse -Filter '*.md' -ErrorAction SilentlyContinue).Count -eq 0)
Check 'no session id: nothing in the project' (-not (Test-Path -LiteralPath (Join-Path (Join-Path $projA '.claude') 'handoff.md')))

$r = Invoke-Script 'brief.ps1' @('-SessionId', 'ffffffff-0000-4000-8000-00000000000f', '-Project', $projA)
Check 'unknown session id: fails' ($r.code -ne 0) "exit $($r.code): $($r.text)"
Check 'unknown session id: writes nothing' (-not (Test-Path -LiteralPath (Get-HandoffFile 'ffffffff-0000-4000-8000-00000000000f')))

$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA, '-Transcript', $trB, '-Project', $projA)
Check 'another session''s transcript is refused' ($r.code -ne 0) "exit $($r.code): $($r.text)"
Check 'refused transcript writes nothing' (-not (Test-Path -LiteralPath (Get-HandoffFile $sidA)))

$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA, '-Transcript', $trA, '-Project', $projB)
Check 'a project the transcript never ran in is refused' ($r.code -ne 0) "exit $($r.code): $($r.text)"

$r = Invoke-Script 'brief.ps1' @('-SessionId', '${CLAUDE_SESSION_ID}', '-Project', $projA)
Check 'an unsubstituted placeholder is not an identity' ($r.code -ne 0) "exit $($r.code): $($r.text)"

$r = Invoke-Script 'brief.ps1' @('-SessionId', '..\..\evil', '-Project', $projA)
Check 'a path-shaped session id is refused' ($r.code -ne 0) "exit $($r.code): $($r.text)"

$r = Invoke-Script 'ctx.ps1' @()
Check 'ctx with no session reports unknown, not the newest file' ($r.text -match 'unknown' -and $r.text -notmatch '999k') $r.text

$r = Invoke-Script 'ctx.ps1' @('-SessionId', $sidA)
Check 'ctx reads the named session' ($r.text -match '111k' -and $r.text -notmatch '999k') $r.text

$scriptsWithGuess = @(Get-ChildItem -LiteralPath $script:ScriptDir -Filter '*.ps1' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Get-NewestTranscript' })
Check 'the newest-transcript fallback is gone' ($scriptsWithGuess.Count -eq 0) (@($scriptsWithGuess.Name) -join ',')

# ---------- attribution ----------
Write-Section 'two projects and two sessions in one project'

# All three at once: nothing but the file name may separate them.
$runs = @(
    (Start-ScriptProcess 'brief.ps1' @('-SessionId', $sidA, '-Transcript', $trA, '-Project', $projA)),
    (Start-ScriptProcess 'brief.ps1' @('-SessionId', $sidA2, '-Transcript', $trA2, '-Project', $projA)),
    (Start-ScriptProcess 'brief.ps1' @('-SessionId', $sidB, '-Transcript', $trB, '-Project', $projB))
)
$results = @($runs | ForEach-Object { Wait-ScriptProcess $_ })
Check 'three simultaneous writers all succeed' (@($results | Where-Object { $_.code -ne 0 }).Count -eq 0) (@($results | ForEach-Object { "$($_.code): $($_.text)" }) -join ' | ')

$pathA = Get-HandoffFile $sidA
$pathA2 = Get-HandoffFile $sidA2
$pathB = Get-HandoffFile $sidB
Check 'each session has its own file' ((Test-Path -LiteralPath $pathA) -and (Test-Path -LiteralPath $pathA2) -and (Test-Path -LiteralPath $pathB))
Check 'nothing lands in a project folder' (-not (Test-Path -LiteralPath (Join-Path $projA '.claude')) -and -not (Test-Path -LiteralPath (Join-Path $projB '.claude')))

$textA = if (Test-Path -LiteralPath $pathA) { [System.IO.File]::ReadAllText($pathA) } else { '' }
$textA2 = if (Test-Path -LiteralPath $pathA2) { [System.IO.File]::ReadAllText($pathA2) } else { '' }
$textB = if (Test-Path -LiteralPath $pathB) { [System.IO.File]::ReadAllText($pathB) } else { '' }
Check 'session A holds its own facts only' ($textA -match 'only-in-a\.ts' -and $textA -notmatch 'only-in-a2|only-in-b|decoy') $textA
Check 'session A2 holds its own facts only' ($textA2 -match 'only-in-a2\.ts' -and $textA2 -notmatch 'only-in-a\.ts|only-in-b|decoy') $textA2
Check 'session B holds its own facts only' ($textB -match 'only-in-b\.ts' -and $textB -notmatch 'only-in-a|decoy') $textB
Check 'front matter names the session' ($textA -match "(?m)^session_id: $sidA\s*$") $textA
Check 'front matter names the project' ($textB -match ('(?m)^project: ' + [regex]::Escape($projB) + '\s*$')) $textB
Check 'front matter names the transcript' ($textA2 -match ('(?m)^transcript: ' + [regex]::Escape($trA2) + '\s*$')) $textA2
Check 'a new handoff starts as a draft' ($textA -match '(?m)^status: draft\s*$') $textA

$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA)
Check 'project and transcript resolve from the exact session id' ($r.code -eq 0) "exit $($r.code): $($r.text)"
$again = if (Test-Path -LiteralPath $pathA) { [System.IO.File]::ReadAllText($pathA) } else { '' }
Check 'resolved run stays with the same session' ($again -match 'only-in-a\.ts' -and $again -notmatch 'decoy') $again

$env:CLAUDE_CODE_SESSION_ID = $sidB
$r = Invoke-Script 'brief.ps1' @()
Remove-Item -LiteralPath Env:CLAUDE_CODE_SESSION_ID
Check 'the session id Claude Code exports is exact enough' ($r.code -eq 0 -and $r.text -match [regex]::Escape($sidB)) "exit $($r.code): $($r.text)"

# ---------- completeness ----------
Write-Section 'required sections are validated before /clear is recommended'

foreach ($section in @('Task goal', 'User constraints', 'Decisions', 'Unresolved problems', 'Verification results', 'Next step')) {
    Check "draft has a '$section' section" ($textA -match "(?m)^## $section\s*$") ''
}
Check 'required sections come before the facts' ($textA.IndexOf('## Next step') -ge 0 -and $textA.IndexOf('## Next step') -lt $textA.IndexOf('## Facts')) ''

$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA)
Check 'writing a draft does not recommend /clear' ($r.text -notmatch '/clear') $r.text

$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA, '-Verify')
Check 'an unfilled draft fails verification' ($r.code -ne 0) "exit $($r.code): $($r.text)"
Check 'failure names the missing sections' ($r.text -match 'Task goal' -and $r.text -match 'Next step') $r.text
Check 'failure does not recommend /clear' ($r.text -notmatch 'run /clear') $r.text
Check 'an unverified handoff stays a draft' ([System.IO.File]::ReadAllText($pathA) -match '(?m)^status: draft\s*$')

Set-HandoffSection $pathA 'Task goal' 'Ship the fix.'
Set-HandoffSection $pathA 'Next step' '_(fill: one concrete action)_'
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA, '-Verify')
Check 'a partly filled draft still fails' ($r.code -ne 0 -and $r.text -notmatch 'Task goal' -and $r.text -match 'User constraints') "exit $($r.code): $($r.text)"

Set-HandoffSection $pathA 'User constraints' '   '
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA, '-Verify')
Check 'a blank section counts as missing' ($r.code -ne 0 -and $r.text -match 'User constraints') "exit $($r.code): $($r.text)"

Set-HandoffComplete $pathA 'AAA'
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidA, '-Verify')
Check 'a complete handoff verifies' ($r.code -eq 0) "exit $($r.code): $($r.text)"
Check 'verification asks the user to run /clear' ($r.text -match '/clear' -and $r.text -match '(?i)user') $r.text
Check 'verification marks it ready' ([System.IO.File]::ReadAllText($pathA) -match '(?m)^status: ready\s*$')
$explicitNone = [System.IO.File]::ReadAllText($pathA)
Check 'an explicit None. is a valid answer' ($explicitNone -match '(?ms)^## Unresolved problems\s+None\.') ''

$oversizedSid = 'eeeeeeee-0000-4000-8000-00000000000e'
$trBig = New-TestTranscript -Project $projA -Sid $oversizedSid -Files @((Join-Path $projA 'big.ts'))
$null = Invoke-Script 'brief.ps1' @('-SessionId', $oversizedSid, '-Transcript', $trBig, '-Project', $projA)
$pathBig = Get-HandoffFile $oversizedSid
Set-HandoffComplete $pathBig 'BIG'
Set-HandoffSection $pathBig 'Decisions' ('x ' * 4000)
$r = Invoke-Script 'brief.ps1' @('-SessionId', $oversizedSid, '-Verify')
Check 'required sections too long to inject are refused' ($r.code -ne 0 -and $r.text -match '(?i)shorten|too long') "exit $($r.code): $($r.text)"
Remove-Item -LiteralPath $pathBig -Force -ErrorAction SilentlyContinue

# ---------- secrets ----------
Write-Section 'synthetic credentials never reach a handoff'

# Assembled at runtime so no secret scanner mistakes this file for a leak. All of
# these are synthetic.
$secrets = [ordered]@{
    github    = 'ghp' + '_' + 'SyntheticToken0123456789abcdefABCDEF01'
    githubPat = 'github' + '_pat_' + '11SYNTHETIC0abcdefghij_klmnopqrstuvwxyz0123456789'
    anthropic = 'sk-' + 'ant-api03-synthetic0123456789abcdefghijklmnop'
    aws       = 'AKIA' + 'SYNTHETIC0000000'
    slack     = 'xox' + 'b-123456789012-synthetic0abcdefgh'
    jwt       = 'eyJ' + 'hbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ.c3ludGhldGljLXNpZ25hdHVyZQ'
    bearer    = 'synthBearerValue0123456789'
    password  = 'hunter2-synthetic-pass'
    envValue  = 'synthEnvValue0123456789'
    urlPass   = 'synthUrlPassw0rd'
    pem       = 'SYNTHETICPEMBODYLINE0123456789'
    psEnv     = 'synthPsEnvValue0123456789'
}
$secretCommands = @(
    "curl -H 'Authorization: Bearer $($secrets.bearer)' https://api.example.test/x",
    "mysql --password=$($secrets.password) -h db.example.test",
    "mytool --token $($secrets.github) deploy-target-zzz",
    "API_KEY=$($secrets.envValue) npm run deploy-target-zzz",
    "git clone https://user:$($secrets.urlPass)@git.example.test/repo.git",
    "aws configure set aws_access_key_id $($secrets.aws)",
    "echo $($secrets.anthropic); echo $($secrets.jwt); echo $($secrets.slack); echo $($secrets.githubPat)",
    "cat <<EOF`n-----BEGIN RSA PRIVATE KEY-----`n$($secrets.pem)`n-----END RSA PRIVATE KEY-----`nEOF",
    "`$env:GITHUB_TOKEN = '$($secrets.psEnv)'; gh auth status"
)
$sidS = 'cccccccc-0000-4000-8000-000000000005'
$trS = New-TestTranscript -Project $projA -Sid $sidS -Commands $secretCommands -Files @((Join-Path $projA 'with-secrets.ts'))

function Get-LeakedNames {
    param([string]$Text)
    return @($secrets.Keys | Where-Object { $Text.Contains($secrets[$_]) })
}

$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidS, '-Transcript', $trS, '-Project', $projA)
$pathS = Get-HandoffFile $sidS
$textS = if (Test-Path -LiteralPath $pathS) { [System.IO.File]::ReadAllText($pathS) } else { '' }
Check 'the secrets session wrote a draft' ($textS.Length -gt 0) $r.text
Check 'default draft holds no secret' (@(Get-LeakedNames $textS).Count -eq 0) (@(Get-LeakedNames $textS) -join ',')
Check 'default draft omits command arguments' ($textS -notmatch 'deploy-target-zzz' -and $textS -notmatch 'example\.test') $textS
Check 'default draft still names the programs' ($textS -match 'curl' -and $textS -match 'mysql' -and $textS -match 'git') $textS
Check 'brief output holds no secret' (@(Get-LeakedNames $r.text).Count -eq 0) $r.text

$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidS, '-Transcript', $trS, '-Project', $projA, '-IncludeCommandArgs')
$textS = if (Test-Path -LiteralPath $pathS) { [System.IO.File]::ReadAllText($pathS) } else { '' }
Check 'opting into arguments shows them' ($textS -match 'deploy-target-zzz') $textS
Check 'opting into arguments still redacts every secret' (@(Get-LeakedNames $textS).Count -eq 0) (@(Get-LeakedNames $textS) -join ',')

Set-HandoffComplete $pathS 'SECRET'
Set-HandoffSection $pathS 'Decisions' "Use token $($secrets.github) and password=$($secrets.password)."
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidS, '-Verify')
$textS = [System.IO.File]::ReadAllText($pathS)
Check 'verification scrubs what the model wrote' ($r.code -eq 0 -and @(Get-LeakedNames $textS).Count -eq 0) "exit $($r.code); leaked $(@(Get-LeakedNames $textS) -join ',')"
Check 'verification says it redacted something' ($r.text -match '(?i)redact') $r.text

# A ready file someone edited by hand afterwards is still scrubbed on the way in.
Set-HandoffSection $pathS 'Decisions' "Hand edited: $($secrets.aws)"
$endS = Invoke-Hook 'session-end.ps1' @{ session_id = $sidS; cwd = $projA; hook_event_name = 'SessionEnd'; reason = 'clear'; transcript_path = $trS }
$startS = Invoke-Hook 'session-start.ps1' @{ session_id = 'new-after-secrets'; cwd = $projA; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'injection scrubs a hand-edited handoff' ($startS.text -match 'Resuming from a handoff' -and @(Get-LeakedNames $startS.text).Count -eq 0) "leaked $(@(Get-LeakedNames $startS.text) -join ','): $($startS.text)"

$everything = @(Get-ChildItem -LiteralPath $script:StateDir -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
Check 'no state file anywhere holds a secret' (@(Get-LeakedNames $everything).Count -eq 0) (@(Get-LeakedNames $everything) -join ',')

# ---------- commands run ----------
Write-Section 'the commands list names programs, not redirections or text'

$sidP = 'cccccccc-0000-4000-8000-000000000006'
$trP = New-TestTranscript -Project $projA -Sid $sidP -Files @((Join-Path $projA 'with-programs.ts')) -Commands @(
    'tool-a --flag 2>&1',
    'tool-b >&2',
    'tool-c *>&1 | Out-String',
    'tool-d >| clobbered-file.txt',
    'tool-e &> all-output.log',
    '"---"; tool-f',
    "'plain-text'; tool-g",
    '--- ; tool-h',
    '& "C:\Program Files\Tool\tool-i.exe" --flag',
    'tool-j && tool-k & tool-l'
)
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidP, '-Transcript', $trP, '-Project', $projA)
$pathP = Get-HandoffFile $sidP
$textP = if (Test-Path -LiteralPath $pathP) { [System.IO.File]::ReadAllText($pathP) } else { '' }
$sectionP = [regex]::Match($textP, '(?s)## Commands run(.*?)(\z|\r?\n## )').Groups[1].Value
$listedP = @([regex]::Matches($sectionP, '(?m)^- (\S+) \(\d+\)\s*$') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
$wantedP = @('Out-String', 'tool-a', 'tool-b', 'tool-c', 'tool-d', 'tool-e', 'tool-f', 'tool-g', 'tool-h', 'tool-i.exe', 'tool-j', 'tool-k', 'tool-l' | Sort-Object)
Check 'the commands list holds exactly the programs' (($listedP -join ',') -ceq ($wantedP -join ',')) "listed: $($listedP -join ', ')"

# ---------- pick-up ----------
Write-Section '/clear picks up the right handoff, once'

Remove-Item -LiteralPath (Join-Path $script:StateDir 'handoffs') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($pair in @(@($sidA, $trA, $projA, 'AAA'), @($sidA2, $trA2, $projA, 'A2A2'), @($sidB, $trB, $projB, 'BBB'))) {
    $null = Invoke-Script 'brief.ps1' @('-SessionId', $pair[0], '-Transcript', $pair[1], '-Project', $pair[2])
    Set-HandoffComplete (Get-HandoffFile $pair[0]) $pair[3]
    $null = Invoke-Script 'brief.ps1' @('-SessionId', $pair[0], '-Verify')
}

# A /clear in a session with no handoff of its own must not take a neighbour's.
$thirdSid = 'cafecafe-0000-4000-8000-000000000006'
$r = Invoke-Hook 'session-end.ps1' @{ session_id = $thirdSid; cwd = $projA; hook_event_name = 'SessionEnd'; reason = 'clear' }
Check 'SessionEnd exits cleanly with no handoff' ($r.code -eq 0) "exit $($r.code): $($r.text)"
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'after-third'; cwd = $projA; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'clearing an unrelated session injects nothing' ($r.text -notmatch 'additionalContext') $r.text
Check 'clearing an unrelated session mentions what is waiting' ($r.text -match 'systemMessage' -and $r.text -match '(?i)handoff') $r.text
Check 'neighbours keep their handoffs' ((Test-Path -LiteralPath (Get-HandoffFile $sidA)) -and (Test-Path -LiteralPath (Get-HandoffFile $sidA2)))

# The real sequence: SessionEnd(clear) on the old id, then SessionStart(clear).
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sidA; cwd = $projA; hook_event_name = 'SessionEnd'; reason = 'clear'; transcript_path = $trA }
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'after-a'; cwd = $projA; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'clear injects the handoff of the session that cleared' ($r.text -match 'Goal of AAA') $r.text
Check 'clear does not inject a neighbour''s handoff' ($r.text -notmatch 'A2A2|Goal of BBB') $r.text
Check 'the injected text leaves the front matter out' ($r.text -notmatch 'session_id:') $r.text
Check 'the consumed handoff leaves the ready set' (-not (Test-Path -LiteralPath (Get-HandoffFile $sidA)))
Check 'the same-project neighbour keeps its handoff' (Test-Path -LiteralPath (Get-HandoffFile $sidA2))
Check 'the other project keeps its handoff' (Test-Path -LiteralPath (Get-HandoffFile $sidB))

$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'after-a-again'; cwd = $projA; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'a handoff is injected once' ($r.text -notmatch 'Goal of AAA') $r.text

# Project boundary: B cleared, a start in project A must not see it.
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sidB; cwd = $projB; hook_event_name = 'SessionEnd'; reason = 'clear'; transcript_path = $trB }
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'wrong-project'; cwd = $projA; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'a claim does not cross projects' ($r.text -notmatch 'Goal of BBB') $r.text
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'right-project'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'the right project still gets it' ($r.text -match 'Goal of BBB') $r.text

# Two ready handoffs cleared at once in one project: refuse to guess.
$sidC1 = 'c1c1c1c1-0000-4000-8000-000000000007'
$sidC2 = 'c2c2c2c2-0000-4000-8000-000000000008'
foreach ($pair in @(@($sidC1, 'CONE'), @($sidC2, 'CTWO'))) {
    $tr = New-TestTranscript -Project $projB -Sid $pair[0]
    $null = Invoke-Script 'brief.ps1' @('-SessionId', $pair[0], '-Transcript', $tr, '-Project', $projB)
    Set-HandoffComplete (Get-HandoffFile $pair[0]) $pair[1]
    $null = Invoke-Script 'brief.ps1' @('-SessionId', $pair[0], '-Verify')
    $null = Invoke-Hook 'session-end.ps1' @{ session_id = $pair[0]; cwd = $projB; hook_event_name = 'SessionEnd'; reason = 'clear'; transcript_path = $tr }
}
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'ambiguous'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'two simultaneous clears inject neither' ($r.text -notmatch 'additionalContext') $r.text
Check 'two simultaneous clears are reported' ($r.text -match 'systemMessage' -and $r.text -match [regex]::Escape((Split-Path -Leaf (Get-HandoffFile $sidC1)))) $r.text
Check 'both ambiguous handoffs survive' ((Test-Path -LiteralPath (Get-HandoffFile $sidC1)) -and (Test-Path -LiteralPath (Get-HandoffFile $sidC2)))
Remove-Item -LiteralPath (Get-HandoffFile $sidC1), (Get-HandoffFile $sidC2) -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath (Join-Path $script:StateDir 'handoffs') -Filter '*.claim' -ErrorAction SilentlyContinue | Remove-Item -Force

# Two starts racing for one claim: exactly one may win.
$sidR = 'abababab-0000-4000-8000-000000000009'
$trR = New-TestTranscript -Project $projB -Sid $sidR
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidR, '-Transcript', $trR, '-Project', $projB)
Set-HandoffComplete (Get-HandoffFile $sidR) 'RACE'
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidR, '-Verify')
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sidR; cwd = $projB; hook_event_name = 'SessionEnd'; reason = 'clear'; transcript_path = $trR }
$payload = @{ session_id = 'racer'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'clear' } | ConvertTo-Json -Compress
$racers = @(1..4 | ForEach-Object { Start-ScriptProcess 'session-start.ps1' @() $payload })
$raceResults = @($racers | ForEach-Object { Wait-ScriptProcess $_ })
$winners = @($raceResults | Where-Object { $_.text -match 'Goal of RACE' }).Count
Check 'racing starts inject a claim exactly once' ($winners -eq 1) "winners=$winners"

# The losing start: a rival renames the handoff after this start listed it. Copies
# of the scripts put the rename exactly between the listing and the age check. A
# throw there would lose everything this start has to report.
$sidV = 'abababab-0000-4000-8000-00000000000e'
$trV = New-TestTranscript -Project $projB -Sid $sidV
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidV, '-Transcript', $trV, '-Project', $projB)
Set-HandoffComplete (Get-HandoffFile $sidV) 'VANISH'
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidV, '-Verify')
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sidV; cwd = $projB; hook_event_name = 'SessionEnd'; reason = 'clear'; transcript_path = $trV }
$realScriptDir = $script:ScriptDir
$script:ScriptDir = Join-Path $script:Sandbox 'scripts-with-rival'
New-Item -ItemType Directory -Force -Path $script:ScriptDir | Out-Null
Copy-Item -LiteralPath (Join-Path $realScriptDir '_common.ps1'), (Join-Path $realScriptDir 'session-start.ps1') -Destination $script:ScriptDir
$rival = @'

$script:RealReadHandoff = ${function:Read-Handoff}
function Read-Handoff {
    param([string]$Path)
    $h = & $script:RealReadHandoff $Path
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Move($Path, "$Path.rival.taken") }
    return $h
}
'@
[System.IO.File]::AppendAllText((Join-Path $script:ScriptDir '_common.ps1'), $rival, $script:Utf8)
Set-TestConfig '{"profile":"creative","mode":"not-a-mode"}'
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'loser'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'clear' }
$script:ScriptDir = $realScriptDir
Set-TestConfig '{}'
Check 'the rival took the handoff' (-not (Test-Path -LiteralPath (Get-HandoffFile $sidV)))
Check 'a vanished handoff keeps the profile note' ($r.text -match 'profile=creative') $r.text
Check 'a vanished handoff keeps the system messages' ($r.text -match 'systemMessage' -and $r.text -match 'not-a-mode') $r.text
Check 'a vanished handoff is not injected' ($r.text -notmatch 'Goal of VANISH') $r.text
Check 'a vanished handoff is not waiting' ($r.text -notmatch 'handoff\(s\) wait') $r.text
Get-ChildItem -LiteralPath (Join-Path $script:StateDir 'handoffs') -Filter "$sidV.*" -ErrorAction SilentlyContinue | Remove-Item -Force

# ---------- startup and other sources ----------
Write-Section 'other session sources'

$sidU = 'dededede-0000-4000-8000-00000000000a'
$trU = New-TestTranscript -Project $projB -Sid $sidU
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidU, '-Transcript', $trU, '-Project', $projB)
Set-HandoffComplete (Get-HandoffFile $sidU) 'UUU'
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidU, '-Verify')

$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'startup-1'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'startup' }
Check 'startup leaves a live session''s handoff alone' ($r.text -notmatch 'Goal of UUU' -and (Test-Path -LiteralPath (Get-HandoffFile $sidU))) $r.text
Check 'startup points at the waiting handoff' ($r.text -match 'systemMessage' -and $r.text -match '(?i)handoff') $r.text

foreach ($source in @('resume', 'fork', 'compact')) {
    $r = Invoke-Hook 'session-start.ps1' @{ session_id = $sidU; cwd = $projB; hook_event_name = 'SessionStart'; source = $source }
    Check "$source does not inject a handoff" ($r.text -notmatch 'Goal of UUU' -and (Test-Path -LiteralPath (Get-HandoffFile $sidU))) $r.text
}

# Exiting ends the session, and VS Code's new chat arrives as a plain startup.
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sidU; cwd = $projB; hook_event_name = 'SessionEnd'; reason = 'prompt_input_exit'; transcript_path = $trU }
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'startup-2'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'startup' }
Check 'startup picks up the only ended session''s handoff' ($r.text -match 'Goal of UUU' -and -not (Test-Path -LiteralPath (Get-HandoffFile $sidU))) $r.text

$sidO = 'edededed-0000-4000-8000-00000000000b'
$trO = New-TestTranscript -Project $projB -Sid $sidO
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidO, '-Transcript', $trO, '-Project', $projB)
Set-HandoffComplete (Get-HandoffFile $sidO) 'OLD'
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidO, '-Verify')
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sidO; cwd = $projB; hook_event_name = 'SessionEnd'; reason = 'other'; transcript_path = $trO }
(Get-Item -LiteralPath (Get-HandoffFile $sidO)).LastWriteTime = (Get-Date).AddHours(-30)
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'startup-3'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'startup' }
Check 'startup ignores a stale handoff' ($r.text -notmatch 'Goal of OLD' -and (Test-Path -LiteralPath (Get-HandoffFile $sidO))) $r.text

# A shared file has no owner, so an old install's brief is announced, not trusted.
$legacyDir = Join-Path $projA '.claude'
New-Item -ItemType Directory -Force -Path $legacyDir | Out-Null
$legacy = Join-Path $legacyDir 'handoff.md'
[System.IO.File]::WriteAllText($legacy, "# Handoff`n`n## Next step`nLEGACY-STEP`n", $script:Utf8)
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'legacy-reader'; cwd = $projA; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'a legacy shared brief is not injected' ($r.text -notmatch 'LEGACY-STEP') $r.text
Check 'a legacy shared brief is reported' ($r.text -match 'systemMessage' -and $r.text -match 'handoff\.md') $r.text
Check 'a legacy shared brief is left in place' (Test-Path -LiteralPath $legacy)
Remove-Item -LiteralPath $legacyDir -Recurse -Force

# Truncation must never eat the part the next session acts on.
$sidT = 'f0f0f0f0-0000-4000-8000-00000000000c'
$manyFiles = @(1..40 | ForEach-Object { Join-Path $projB ("deep/folder/with/a/rather/long/path/segment/file-number-$_.ts") })
$trT = New-TestTranscript -Project $projB -Sid $sidT -Files $manyFiles
$null = Invoke-Script 'brief.ps1' @('-SessionId', $sidT, '-Transcript', $trT, '-Project', $projB)
Set-HandoffComplete (Get-HandoffFile $sidT) 'TRUNC'
Set-HandoffSection (Get-HandoffFile $sidT) 'Decisions' ('Decision detail. ' * 300)
Set-HandoffSection (Get-HandoffFile $sidT) 'Facts' (('- fact line that is padding for the size limit' + "`n") * 120)
$r = Invoke-Script 'brief.ps1' @('-SessionId', $sidT, '-Verify')
Check 'long facts do not fail verification' ($r.code -eq 0) "exit $($r.code): $($r.text)"
$null = Invoke-Hook 'session-end.ps1' @{ session_id = $sidT; cwd = $projB; hook_event_name = 'SessionEnd'; reason = 'clear'; transcript_path = $trT }
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'after-trunc'; cwd = $projB; hook_event_name = 'SessionStart'; source = 'clear' }
Check 'truncating an oversize handoff keeps the Next step' ($r.text -match 'Next step of TRUNC' -and $r.text -match 'truncated') $r.text.Substring(0, [Math]::Min(300, $r.text.Length))

Complete-TestRun 'handoff tests'
