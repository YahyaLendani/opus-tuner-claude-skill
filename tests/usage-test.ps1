# Usage and cost figures against synthetic transcripts with known totals, worked
# out by hand in tests/fixtures/usage/expected.json.
#
# They use the pinned rates in tests/fixtures/usage/pricing-pinned.json, so a later
# price update to the shipped table does not move these totals.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/usage-test.ps1
#   pwsh -NoProfile -File tests/usage-test.ps1

param([string]$Interpreter = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
$script:Interpreter = Get-TestInterpreter $Interpreter
$null = New-TestSandbox 'usage'

$fixtures = Join-Path (Join-Path $PSScriptRoot 'fixtures') 'usage'
$expected = [System.IO.File]::ReadAllText((Join-Path $fixtures 'expected.json')) | ConvertFrom-Json
$projects = Join-Path $script:ClaudeDir 'projects'
$project = Join-Path $projects 'fixture'
New-Item -ItemType Directory -Force -Path $project | Out-Null

# Oldest first in the order of expected.json, so the replayed record belongs to the
# older file whichever way the checkout stamped them.
$age = 100
foreach ($p in $expected.sessions.PSObject.Properties) {
    $to = Join-Path $project "$($p.Name).jsonl"
    Copy-Item -LiteralPath (Join-Path $fixtures "$($p.Name).jsonl") -Destination $to
    (Get-Item -LiteralPath $to).LastWriteTime = (Get-Date).AddHours(-$age)
    $age--
}

function Test-Near { param($A, $B) return ($null -ne $A -and [Math]::Abs([double]$A - [double]$B) -lt 1e-9) }

Write-Host "usage tests  (interpreter: $($script:Interpreter))" -ForegroundColor Cyan

$pinned = Join-Path $fixtures 'pricing-pinned.json'
$bundled = Join-Path (Join-Path (Join-Path (Join-Path $script:RepoRoot 'skills') 'opus-tuner') 'references') 'pricing.json'

Write-Section 'the pricing table'
Check 'a pricing table ships with the skill' (Test-Path -LiteralPath $bundled) $bundled
$table = [System.IO.File]::ReadAllText($pinned) | ConvertFrom-Json
if (Test-Path -LiteralPath $bundled) {
    $shipped = [System.IO.File]::ReadAllText($bundled) | ConvertFrom-Json
    Check 'it has a schema and a version' ($shipped.schema -eq 1 -and [string]$shipped.version) ([string]$shipped.version)
    Check 'it names its source' ([string]$shipped.source -match 'pricing') ([string]$shipped.source)
    foreach ($m in @('claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1')) {
        Check "it prices $m" ($null -ne $shipped.models.$m)
    }
    foreach ($e in $shipped.models.PSObject.Properties) {
        $whole = ($null -ne $e.Value.input -and $null -ne $e.Value.output -and $null -ne $e.Value.cacheRead -and $null -ne $e.Value.cacheWrite5m -and $null -ne $e.Value.cacheWrite1h)
        Check "$($e.Name) has all five rates" $whole
    }
    Set-TestConfig '{}'
    $r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Json')
    $j0 = $null
    try { $j0 = $r.text | ConvertFrom-Json } catch { }
    Check 'with nothing configured, the shipped table is used' ($j0 -and [string]$j0.pricingVersion -eq [string]$shipped.version) $r.text
}
Set-TestConfig ('{"pricingFile":' + (ConvertTo-Json $pinned) + '}')

Write-Section 'costs per request, in JSON'
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Json')
Check 'audit -Json exits 0' ($r.code -eq 0) $r.text
$j = $null
try { $j = $r.text | ConvertFrom-Json } catch { }
Check 'audit -Json prints JSON' ($null -ne $j) $r.text
$rows = @{}
if ($j) { foreach ($s in @($j.sessions)) { $rows[[string]$s.Session] = $s } }

foreach ($p in $expected.sessions.PSObject.Properties) {
    $want = $p.Value
    $got = $rows[$p.Name]
    Check "$($p.Name) is reported" ($null -ne $got)
    if (-not $got) { continue }
    Check "$($p.Name): requests" ([int]$got.Requests -eq [int]$want.requests) "got $($got.Requests), want $($want.requests)"
    Check "$($p.Name): cost at full precision" (Test-Near $got.CostUSD $want.costUSD) "got $($got.CostUSD), want $($want.costUSD): $($want.why)"
    Check "$($p.Name): peak context" (Test-Near (1000.0 * [double]$got.PeakCtxK) $want.peak) "got $($got.PeakCtxK)k, want $($want.peak)"
    Check "$($p.Name): unknown-priced requests" ([int]$got.UnknownRequests -eq [int]$want.unknown) "got $($got.UnknownRequests), want $($want.unknown)"
    Check "$($p.Name): assumed cache writes" ([int64]$got.AssumedWriteTokens -eq [int64]$want.assumedWrite) "got $($got.AssumedWriteTokens), want $($want.assumedWrite)"
}

$t = if ($j) { $j.totals } else { $null }
Check 'total requests' ($t -and [int]$t.requests -eq [int]$expected.totals.requests) "got $($t.requests)"
Check 'total cost keeps full precision' ($t -and (Test-Near $t.costUSD $expected.totals.costUSD)) "got $($t.costUSD), want $($expected.totals.costUSD)"
Check 'duplicates are counted once, and reported' ($j -and [int]$j.duplicateRecords -eq [int]$expected.totals.duplicates) "got $($j.duplicateRecords)"
Check 'an unreadable line is reported, not silently dropped' ($j -and [int]$j.unparsedLines -eq [int]$expected.totals.unparsed) "got $($j.unparsedLines)"
Check 'unknown models are named' ($j -and (@($j.unknownPricing.models) -contains 'claude-future-9') -and (@($j.unknownPricing.models) -contains 'claude-opus-9')) (@($j.unknownPricing.models) -join ', ')
Check 'an unknown request count is given' ($j -and [int]$j.unknownPricing.requests -eq [int]$expected.totals.unknownRequests) "got $($j.unknownPricing.requests)"
Check 'the report names the pricing version' ($j -and [string]$j.pricingVersion -eq [string]$table.version) "got $($j.pricingVersion)"
Check 'JSON labels the estimate' ($j -and [string]$j.estimateLabel -match '(?i)API-equivalent' -and [string]$j.estimateLabel -match '(?i)not your bill') "got $($j.estimateLabel)"
$side = $rows['sidechai']
Check 'requested and served model differences are counted' ($side -and [int]$side.ModelMismatches -eq 1) "got $($side.ModelMismatches)"
Check 'effort from the transcript is reported per request' ($side -and [string]$side.Effort -match 'xhigh' -and [string]$side.Effort -match 'high') "got $($side.Effort)"
Check 'each model is listed for a mixed session' ($rows['mixedmod'] -and [string]$rows['mixedmod'].Models -match 'claude-opus-5-5' -and [string]$rows['mixedmod'].Models -match 'claude-haiku-5-5') "got $($rows['mixedmod'].Models)"

Write-Section 'the printed report'
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0')
Check 'it labels the estimate' ($r.text -match '(?i)API-equivalent' -and $r.text -match '(?i)not your bill') $r.text
Check 'it does not price everything at one rate' ($r.text -notmatch '(?i)opus rates') $r.text
Check 'it says the total is a lower bound when models are unknown' ($r.text -match '(?i)lower bound' -and $r.text -match 'claude-future-9') $r.text
Check 'it says what it assumed about cache writes' ($r.text -match '(?i)5m') $r.text
Check 'it rounds for display' ($r.text -match '0[.,]11\b' -and $r.text -notmatch '0[.,]10982') $r.text
Check 'it reports skipped duplicates' ($r.text -match '(?i)duplicate') $r.text

Write-Section 'CSV and baselines'
$csv = Join-Path $script:Sandbox 'now.csv'
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Csv', $csv)
$c = @()
if (Test-Path -LiteralPath $csv) { $c = @(Import-Csv -LiteralPath $csv) }
$mix = @($c | Where-Object { $_.Session -eq 'mixedmod' })
Check 'the CSV keeps full precision' ($mix.Count -eq 1 -and (Test-Near $mix[0].CostUSD 0.05378)) "got $(if ($mix.Count) { $mix[0].CostUSD })"
Check 'the CSV records the pricing version' ($mix.Count -eq 1 -and [string]$mix[0].PricingVersion -eq [string]$table.version)
Check 'the CSV keeps the baseline columns' ($mix.Count -eq 1 -and $null -ne $mix[0].Requests -and $null -ne $mix[0].CacheReadM -and $null -ne $mix[0].PeakCtxK)

$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Baseline', $csv)
Check 'a baseline with a pricing version compares cleanly' ($r.text -match 'baseline comparison' -and $r.text -notmatch '(?i)pricing version') $r.text
Check 'the comparison shows cents, not whole dollars' ($r.text -match 'cost \(USD\)\s+0[.,]11') $r.text

$old = Join-Path $script:Sandbox 'old.csv'
[System.IO.File]::WriteAllLines($old, @('Session,MB,Requests,CacheReadM,CacheWrM,OutputK,PeakCtxK,Model,CostUSD,LastWrite', 'old,1,10,5,1,1,300,opus,12,01-01'))
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Baseline', $old)
Check 'an older baseline still compares' ($r.text -match 'baseline comparison') $r.text
Check 'an older baseline is flagged as not comparable' ($r.text -match '(?i)before 0\.7|no pricing version') $r.text

Write-Section 'pricing is configurable, and absence is explicit'
$custom = Join-Path $script:Sandbox 'custom.json'
$customText = '{"schema":1,"version":"custom-1","source":"pricing test","models":{"claude-future-9":{"input":1,"output":2,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}}}'
[System.IO.File]::WriteAllText($custom, $customText, $script:Utf8)
Set-TestConfig ('{"pricingFile":' + (ConvertTo-Json $custom) + '}')
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Json')
$j2 = $null
try { $j2 = $r.text | ConvertFrom-Json } catch { }
Check 'the config can point at another table' ($j2 -and [string]$j2.pricingVersion -eq 'custom-1') $r.text
$unk = @(if ($j2) { $j2.sessions | Where-Object { $_.Session -eq 'unknownm' } })
Check 'its rates are used' ($unk.Count -eq 1 -and (Test-Near $unk[0].CostUSD 0.3)) "got $(if ($unk.Count) { $unk[0].CostUSD })"
Set-TestConfig ('{"pricingFile":' + (ConvertTo-Json (Join-Path $script:Sandbox 'nope.json')) + '}')
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Json')
$j3 = $null
try { $j3 = $r.text | ConvertFrom-Json } catch { }
Check 'a missing table gives no cost, not a zero' ($j3 -and $null -eq $j3.totals.costUSD) $r.text
Check 'token counts survive a missing table' ($j3 -and [int]$j3.totals.requests -eq [int]$expected.totals.requests) $r.text
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0')
Check 'a missing table is stated in the report' ($r.text -match '(?i)pricing.*(unavailable|not found|could not)') $r.text
Set-TestConfig ('{"pricingFile":' + (ConvertTo-Json $pinned) + '}')

Write-Section 'one very long line'
$big = Join-Path $projects 'big'
New-Item -ItemType Directory -Force -Path $big | Out-Null
$long = 'x' * 3000000
$bigLine = '{"type":"assistant","uuid":"big-1","requestId":"req_big","message":{"id":"msg_big","model":"claude-opus-5-5","content":[{"type":"text","text":"' + $long + ' with \"quotes\" and \\ slashes"}],"usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}'
[System.IO.File]::WriteAllText((Join-Path $big 'bigline1.jsonl'), $bigLine + "`n", $script:Utf8)
$r = Invoke-Script -Name 'audit.ps1' -Arguments @('-Recent', '0', '-Project', 'big', '-Json')
$j4 = $null
try { $j4 = $r.text | ConvertFrom-Json } catch { }
Check 'a 3 MB line is counted' ($j4 -and [int]$j4.totals.requests -eq 1 -and (Test-Near $j4.totals.costUSD 0.004)) $r.text

Write-Section 'context size for the hooks'
$cases = @(
    @{ name = 'nestedus'; ctx = 1310; model = 'claude-opus-5-5'; why = 'a toolUseResult after it, nested iterations, usage quoted in text' }
    @{ name = 'reorderd'; ctx = 1200; model = 'claude-sonnet-5'; why = 'message before type, usage before model' }
    @{ name = 'spacedfd'; ctx = 200; model = 'claude-opus-4-8'; why = 'spaces around every colon' }
    @{ name = 'sidechai'; ctx = 100; model = 'claude-opus-5-5'; why = 'a subagent record last' }
    @{ name = 'unknownm'; ctx = 100; model = 'claude-opus-5-5'; why = 'an all-zero record last' }
)
foreach ($c in $cases) {
    $r = Invoke-Script -Name 'ctx.ps1' -Arguments @('-Transcript', (Join-Path $project "$($c.name).jsonl"), '-Json')
    $info = $null
    try { $info = $r.text | ConvertFrom-Json } catch { }
    Check "$($c.name): context with $($c.why)" ($info -and [int64]$info.context -eq $c.ctx) $r.text
    Check "$($c.name): model of that same record" ($info -and [string]$info.model -eq $c.model) $r.text
}

Write-Section 'the decision log'
$log = Join-Path $script:StateDir 'decisions.csv'
$old = (Get-Date).AddMinutes(-5).ToString('o')
[System.IO.File]::WriteAllText($log, "time,session,ctx,tier,gear,action`r`n$old,aaaa1111,150000,routine,low,gear-low`r`n$old,aaaa1111,250000,deep,high,hard-wrap`r`n", $script:Utf8)
$r = Invoke-Script -Name 'stats.ps1'
Check 'stats keeps recent rows under the default filter' ($r.text -match 'decisions: 2') $r.text
Check 'stats reads the context column' ($r.text -match '200k' -or $r.text -match '150k') $r.text

$p = @{ session_id = 'efforta1'; cwd = $script:Sandbox; transcript_path = (Join-Path $project 'mixedmod.jsonl'); hook_event_name = 'PreCompact'; trigger = 'auto'; effort = @{ level = 'xhigh' } }
$null = Invoke-Hook 'pre-compact.ps1' $p
$rows2 = @(Import-Csv -LiteralPath $log)
$new = @($rows2 | Where-Object { $_.session -eq 'efforta1' })
Check 'older rows survive the new column' (@($rows2 | Where-Object { $_.session -eq 'aaaa1111' }).Count -eq 2) ($rows2.Count)
Check 'the log has a separate effective effort column' ($rows2.Count -gt 0 -and $rows2[0].PSObject.Properties.Name -contains 'effective_effort') (($rows2[0].PSObject.Properties.Name) -join ',')
Check 'it records what the hook reported' ($new.Count -eq 1 -and $new[0].effective_effort -eq 'xhigh') "got $(if ($new.Count) { $new[0].effective_effort })"
Check 'the requested gear stays in its own column' ($new.Count -eq 1 -and $new[0].gear -ne 'xhigh') "got $(if ($new.Count) { $new[0].gear })"
$env:CLAUDE_EFFORT = 'medium'
$p['session_id'] = 'effortb1'
$p.Remove('effort')
$null = Invoke-Hook 'pre-compact.ps1' $p
Remove-Item Env:CLAUDE_EFFORT
$new = @(Import-Csv -LiteralPath $log | Where-Object { $_.session -eq 'effortb1' })
Check 'it falls back to CLAUDE_EFFORT' ($new.Count -eq 1 -and $new[0].effective_effort -eq 'medium') "got $(if ($new.Count) { $new[0].effective_effort })"
$p['session_id'] = 'effortc1'
$null = Invoke-Hook 'pre-compact.ps1' $p
$new = @(Import-Csv -LiteralPath $log | Where-Object { $_.session -eq 'effortc1' })
Check 'it stays blank when nothing reported one' ($new.Count -eq 1 -and -not $new[0].effective_effort) "got $(if ($new.Count) { $new[0].effective_effort })"
$r = Invoke-Script -Name 'stats.ps1'
Check 'stats separates requested from reported effort' ($r.text -match '(?i)requested' -and $r.text -match 'xhigh') $r.text

Write-Section 'the weekly summary'
Remove-Item -LiteralPath (Join-Path $script:StateDir 'digest.stamp') -Force
$r = Invoke-Hook 'session-start.ps1' @{ session_id = 'digest-test'; cwd = $script:Sandbox; source = 'startup'; hook_event_name = 'SessionStart' }
Check 'the digest appears' ($r.text -match 'last 7 days' -and $r.text -match 'gear switch') $r.text
Check 'it reports tokens, not a dollar figure from one fixed rate' ($r.text -notmatch '\$\d' -and $r.text -match '(?i)re-read') $r.text

Complete-TestRun 'usage tests'
