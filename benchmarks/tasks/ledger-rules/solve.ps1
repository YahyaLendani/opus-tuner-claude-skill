# A reference solution, to prove the grader passes correct work and fails work that
# ignores the task's rules. No live run sees this file.
param([string]$Path, [string]$Step, [switch]$Violate)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$ledger = Join-Path (Join-Path $Path 'src') 'ledger.ps1'

if ($Step -eq 'phase1') {
    [System.IO.File]::WriteAllText($ledger, @'
function Get-Total {
    param([object[]]$Entries)
    $total = 0
    foreach ($e in $Entries) {
        switch ($e.kind) {
            'sale' { $total += $e.cents }
            'refund' { $total -= $e.cents }
            default { throw "unknown kind: $($e.kind)" }
        }
    }
    return $total
}
'@, $utf8)
}

if ($Step -eq 'phase2') {
    $format = if ($Violate) {
        'function Format-Amount { param([int]$Cents) return ([double]$Cents / 100).ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture) }'
    } else {
        @'
function Format-Amount {
    param([int]$Cents)
    $sign = if ($Cents -lt 0) { '-' } else { '' }
    $abs = [Math]::Abs($Cents)
    return ('{0}{1}.{2:00}' -f $sign, [Math]::Floor($abs / 100), ($abs % 100))
}
'@
    }
    $add = @'

function Get-Balance {
    param([object[]]$Entries, [string]$Account)
    return Get-Total @($Entries | Where-Object { $_.account -eq $Account })
}

'@ + $format + "`n"
    [System.IO.File]::AppendAllText($ledger, $add, $utf8)
    $tests = Join-Path (Join-Path $Path 'tests') 'run-tests.ps1'
    $text = [System.IO.File]::ReadAllText($tests)
    $more = "Assert-Equal 'balance' (Get-Balance -Entries `$entries -Account 'a') 750`nAssert-Equal 'format' (Format-Amount -Cents 1234) '12.34'`nexit `$failed"
    [System.IO.File]::WriteAllText($tests, $text.Replace('exit $failed', $more), $utf8)
}
