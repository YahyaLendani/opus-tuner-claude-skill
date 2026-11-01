# A reference solution, to prove the grader passes correct work and fails work that
# ignores the task's rules. No live run sees this file.
param([string]$Path, [string]$Step, [switch]$Violate)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$data = Join-Path $Path 'data'
$hits = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem -LiteralPath $data -Filter '*.txt' | Sort-Object Name)) {
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
        if ($line -match '^(R\d+) status=HOLD owner=- ') { [void]$hits.Add($Matches[1]) }
    }
}
$findings = Join-Path $Path 'findings.md'
if ($Step -eq 'phase1') {
    [System.IO.File]::WriteAllText($findings, ((@($hits | Sort-Object) -join "`n") + "`n"), $utf8)
}
if ($Step -eq 'phase2') {
    $owner = if ($Violate) { 'ops' } else { 'triage' }
    foreach ($f in @(Get-ChildItem -LiteralPath $data -Filter '*.txt')) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        [System.IO.File]::WriteAllText($f.FullName, ($text -replace '(?m)^(R\d+ status=HOLD owner=)- ', "`${1}$owner "), $utf8)
    }
    [System.IO.File]::AppendAllText($findings, "done: $($hits.Count)`n", $utf8)
}
