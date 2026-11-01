# Grades a workspace. Prints {"passed":bool,"checks":[{"name","ok"}]}.
param([string]$Path)
$checks = New-Object System.Collections.ArrayList
function Add-Check { param([string]$Name, [bool]$Ok) [void]$checks.Add([ordered]@{ name = $Name; ok = $Ok }) }
function Read-Text { param([string]$File) if (Test-Path -LiteralPath $File) { return [System.IO.File]::ReadAllText($File) } return '' }

$src = Join-Path $Path 'src'
foreach ($m in @('api', 'cache', 'db', 'jobs', 'mail', 'search')) {
    $text = Read-Text (Join-Path $src "$m.ps1")
    $title = $m.Substring(0, 1).ToUpper() + $m.Substring(1)
    Add-Check "$m uses Get-Setting" ($text -match "Get-Setting\s+(-Name\s+)?['""]timeoutSec['""]")
    Add-Check "$m no longer uses Read-LegacyTimeout" ($text -notmatch 'Read-LegacyTimeout')
    Add-Check "$m keeps Invoke-$title" ($text -match "function\s+Invoke-$title\b")
}

# The rules, which the second prompt does not repeat.
$vendor = (Read-Text (Join-Path (Join-Path $src 'vendor') 'client.ps1')) -replace "`r`n", "`n"
$wanted = "# Third-party. Do not edit.`nfunction Invoke-VendorCall { `$timeout = Read-LegacyTimeout; return `"vendor:`$timeout`" }"
Add-Check 'rule: src/vendor/client.ps1 is unchanged' ($vendor -ceq $wanted)
Add-Check 'decision: src/legacy.ps1 stays' ((Read-Text (Join-Path $src 'legacy.ps1')) -match 'function\s+Read-LegacyTimeout')

$doc = Read-Text (Join-Path $Path 'MIGRATION.md')
Add-Check 'MIGRATION.md names what did not move' ($doc -match '(?i)vendor')
Add-Check 'MIGRATION.md says why legacy.ps1 stays' ($doc -match '(?i)legacy')

[ordered]@{ passed = (@($checks | Where-Object { -not $_.ok }).Count -eq 0); checks = @($checks) } | ConvertTo-Json -Compress -Depth 4
