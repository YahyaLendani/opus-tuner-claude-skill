# What the tuner actually did. Reads state/tuner/decisions.csv, which route.ps1
# and stop.ps1 append to only when they make a decision - not on every prompt.
#
#   powershell -NoProfile -File stats.ps1          # last 7 days
#   powershell -NoProfile -File stats.ps1 -Days 30
#   powershell -NoProfile -File stats.ps1 -All

param([int]$Days = 7, [switch]$All)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$log = Join-Path $script:TunerState 'decisions.csv'
if (-not (Test-Path -LiteralPath $log)) {
    "no decisions logged yet: $log"
    exit 0
}

$rows = @(Import-Csv -LiteralPath $log)
if (-not $All -and $Days -gt 0) {
    $cut = (Get-Date).AddDays(-$Days)
    $rows = @($rows | Where-Object {
        $t = [datetime]::MinValue
        [void][datetime]::TryParse([string]$_['time'], [ref]$t)
        $t -ge $cut
    })
}

if ($rows.Count -eq 0) {
    "no decisions in the last $Days day(s)"
    exit 0
}

"decisions: $($rows.Count)"

''
'by action:'
$rows | Group-Object { $_.action } | Sort-Object Count -Descending | ForEach-Object {
    $ctxs = @($_.Group | ForEach-Object { [int64]$_['ctx'] })
    $avg = [int64](($ctxs | Measure-Object -Average).Average)
    $min = [int64]($ctxs | Measure-Object -Minimum).Minimum
    $max = [int64]($ctxs | Measure-Object -Maximum).Maximum
    "{0,-16} {1,4}  ctx avg {2,6}  min {3,6}  max {4,6}" -f $_.Name, $_.Count, (Format-Tokens $avg), (Format-Tokens $min), (Format-Tokens $max)
}

''
'by day:'
$rows | Group-Object {
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$_['time'], [ref]$t)) { $t.ToString('yyyy-MM-dd') } else { 'unknown' }
} | Sort-Object Name | ForEach-Object {
    "{0}  {1,3} decisions" -f $_.Name, $_.Count
}

''
'reading it: many gear rows at small ctx means the downshift threshold is too low.'
'hard-wrap rows are sessions that hit the ceiling; one per session is healthy,'
'several in a day means the ceiling is being treated as a suggestion.'
