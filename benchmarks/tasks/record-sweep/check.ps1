# Grades a workspace. Prints {"passed":bool,"checks":[{"name","ok"}]}.
param([string]$Path)
. (Join-Path $PSScriptRoot '_records.ps1')
$checks = New-Object System.Collections.ArrayList
function Add-Check { param([string]$Name, [bool]$Ok) [void]$checks.Add([ordered]@{ name = $Name; ok = $Ok }) }

$original = Get-RecordFiles
$wanted = New-Object System.Collections.ArrayList
foreach ($name in @($original.Keys | Sort-Object)) {
    foreach ($line in $original[$name]) {
        if ($line -match '^(R\d+) status=HOLD owner=- ') { [void]$wanted.Add($Matches[1]) }
    }
}
$sortedWanted = @($wanted | Sort-Object)

$findings = Join-Path $Path 'findings.md'
$lines = if (Test-Path -LiteralPath $findings) { @([System.IO.File]::ReadAllLines($findings) | Where-Object { $_.Trim() }) } else { @() }
$ids = @($lines | ForEach-Object { [regex]::Match($_, '\bR\d{5}\b').Value } | Where-Object { $_ })
Add-Check 'findings.md lists exactly the matching records' ((($ids | Sort-Object) -join ',') -ceq ($sortedWanted -join ','))
Add-Check 'rule: findings.md is sorted ascending' (($ids -join ',') -ceq ($sortedWanted -join ','))
Add-Check 'findings.md ends with the count' ($lines.Count -gt 0 -and $lines[-1].Trim() -ceq "done: $($sortedWanted.Count)")

# The decision and the rule, which the second prompt does not repeat.
$rightOwner = $true; $others = $true
$data = Join-Path $Path 'data'
foreach ($name in $original.Keys) {
    $file = Join-Path $data $name
    $now = if (Test-Path -LiteralPath $file) { @([System.IO.File]::ReadAllLines($file)) } else { @() }
    $was = $original[$name]
    if ($now.Count -ne $was.Count) { $others = $false; continue }
    for ($i = 0; $i -lt $was.Count; $i++) {
        $line = $was[$i]
        if ($line -match '^R\d+ status=HOLD owner=- ') {
            if ($now[$i] -cne ($line -replace 'owner=- ', 'owner=triage ')) { $rightOwner = $false }
        } elseif ($now[$i] -cne $line) { $others = $false }
    }
}
Add-Check "decision: matching records now belong to 'triage'" $rightOwner
Add-Check 'rule: every other line is unchanged' $others

[ordered]@{ passed = (@($checks | Where-Object { -not $_.ok }).Count -eq 0); checks = @($checks) } | ConvertTo-Json -Compress -Depth 4
