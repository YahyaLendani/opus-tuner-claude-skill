param([string]$Path)
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path (Join-Path $Path 'src'), (Join-Path $Path 'tests') | Out-Null

[System.IO.File]::WriteAllText((Join-Path (Join-Path $Path 'src') 'ledger.ps1'), @'
# Entries have .kind ('sale' or 'refund'), .cents (a positive integer) and .account.
function Get-Total {
    param([object[]]$Entries)
    $total = 0
    foreach ($e in $Entries) {
        if ($e.kind -eq 'sale') { $total += $e.cents }
        if ($e.kind -eq 'refund') { $total += $e.cents }
    }
    return $total
}
'@, $utf8)

[System.IO.File]::WriteAllText((Join-Path (Join-Path $Path 'tests') 'run-tests.ps1'), @'
. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') 'ledger.ps1')
$failed = 0
function Assert-Equal($Name, $Got, $Want) {
    if ($Got -eq $Want) { "PASS $Name" } else { "FAIL $Name got $Got want $Want"; $script:failed++ }
}
$entries = @(
    [pscustomobject]@{ kind = 'sale'; cents = 1000; account = 'a' }
    [pscustomobject]@{ kind = 'refund'; cents = 250; account = 'a' }
)
Assert-Equal 'a refund reduces the total' (Get-Total $entries) 750
exit $failed
'@, $utf8)
