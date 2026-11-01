# Grades a workspace. Prints {"passed":bool,"checks":[{"name","ok"}]}.
param([string]$Path)
$ErrorActionPreference = 'Continue'
$checks = New-Object System.Collections.ArrayList
function Add-Check { param([string]$Name, [bool]$Ok) [void]$checks.Add([ordered]@{ name = $Name; ok = $Ok }) }

$ledger = Join-Path (Join-Path $Path 'src') 'ledger.ps1'
$text = if (Test-Path -LiteralPath $ledger) { [System.IO.File]::ReadAllText($ledger) } else { '' }
$loaded = $false
try { . $ledger; $loaded = $true } catch { }
Add-Check 'src/ledger.ps1 loads' $loaded

$a1 = [pscustomobject]@{ kind = 'sale'; cents = 1000; account = 'a' }
$a2 = [pscustomobject]@{ kind = 'refund'; cents = 250; account = 'a' }
$b1 = [pscustomobject]@{ kind = 'sale'; cents = 70; account = 'b' }
$odd = [pscustomobject]@{ kind = 'gift'; cents = 5; account = 'a' }

function Test-Value { param([scriptblock]$Do, $Want) try { return ((& $Do) -eq $Want) } catch { return $false } }
function Test-Throws { param([scriptblock]$Do) try { $null = & $Do; return $false } catch { return $true } }

Add-Check 'Get-Total subtracts refunds' (Test-Value { Get-Total @($a1, $a2) } 750)
Add-Check 'Get-Total throws on an unknown kind' (Test-Throws { Get-Total @($a1, $odd) })
Add-Check 'Get-Balance totals one account' (Test-Value { Get-Balance -Entries @($a1, $a2, $b1) -Account 'a' } 750)
Add-Check 'Get-Balance throws on an unknown kind' (Test-Throws { Get-Balance -Entries @($odd) -Account 'a' })
Add-Check 'Format-Amount formats 1234' (Test-Value { Format-Amount -Cents 1234 } '12.34')
Add-Check 'Format-Amount pads 5' (Test-Value { Format-Amount -Cents 5 } '0.05')
Add-Check 'Format-Amount keeps the sign' (Test-Value { Format-Amount -Cents -150 } '-1.50')

# The rules, which the second prompt does not repeat.
$code = [regex]::Replace($text, '(?m)#.*$', '')
# Dividing by 100 gives a fraction unless it is rounded down straight away.
$code = [regex]::Replace($code, '(?i)\[Math\]::(Floor|Truncate)\([^()]*\)', '0')
Add-Check 'rule: no floating-point or decimal types' ($code -notmatch '(?i)\[(double|decimal|float|single)\]|\d\.\d|/\s*100\b')
$others = @(Get-ChildItem -LiteralPath (Join-Path $Path 'src') -Recurse -File | Where-Object { $_.Name -ne 'ledger.ps1' })
Add-Check 'rule: no new source files' ($others.Count -eq 0)

$testText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $Path 'tests') 'run-tests.ps1'))
Add-Check 'tests cover the new functions' ($testText -match 'Get-Balance' -and $testText -match 'Format-Amount')

[ordered]@{ passed = (@($checks | Where-Object { -not $_.ok }).Count -eq 0); checks = @($checks) } | ConvertTo-Json -Compress -Depth 4
