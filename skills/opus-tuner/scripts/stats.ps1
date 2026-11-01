# What the tuner actually did. Reads state/tuner/decisions.csv, which route.ps1
# and stop.ps1 append to only when they make a decision - not on every prompt.
#
#   powershell -NoProfile -File stats.ps1          # last 7 days
#   powershell -NoProfile -File stats.ps1 -Days 30
#   powershell -NoProfile -File stats.ps1 -All

param([int]$Days = 7, [switch]$All)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

function ConvertTo-RowTime {
    param($Row)
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Row.time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return $t }
    return $null
}

$log = Join-Path $script:TunerState 'decisions.csv'
if (-not (Test-Path -LiteralPath $log)) {
    "no decisions logged yet: $log"
    exit 0
}

$rows = @(Import-Csv -LiteralPath $log)
if (-not $All -and $Days -gt 0) {
    $cut = (Get-Date).AddDays(-$Days)
    $rows = @($rows | Where-Object {
        $t = ConvertTo-RowTime $_
        $null -ne $t -and $t -ge $cut
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
    $ctxs = @($_.Group | ForEach-Object {
        $n = [int64]0
        [void][int64]::TryParse([string]$_.ctx, [ref]$n)
        $n
    })
    $avg = [int64](($ctxs | Measure-Object -Average).Average)
    $min = [int64]($ctxs | Measure-Object -Minimum).Minimum
    $max = [int64]($ctxs | Measure-Object -Maximum).Maximum
    "{0,-16} {1,4}  ctx avg {2,6}  min {3,6}  max {4,6}" -f $_.Name, $_.Count, (Format-Tokens $avg), (Format-Tokens $min), (Format-Tokens $max)
}

''
'by day:'
$rows | Group-Object {
    $t = ConvertTo-RowTime $_
    if ($null -ne $t) { $t.ToString('yyyy-MM-dd') } else { 'unknown' }
} | Sort-Object Name | ForEach-Object {
    "{0}  {1,3} decisions" -f $_.Name, $_.Count
}

# Only rows where Claude Code said what the turn ran at. The router's gear is a
# request, and this is the nearest thing to confirmation that it took effect.
$reported = @($rows | Where-Object { $_.effective_effort })
if ($reported.Count -gt 0) {
    ''
    'requested gear -> effort Claude Code reported:'
    $reported | Group-Object {
        $asked = if ($_.gear) { $_.gear } else { '(none)' }
        "$asked -> $($_.effective_effort)"
    } | Sort-Object Name | ForEach-Object {
        "{0,-24} {1,4}" -f $_.Name, $_.Count
    }
}

''
'reading it: many gear rows at small ctx means the downshift threshold is too low.'
'hard-wrap rows are one-time Stop prompts at the ceiling, in guard mode. They show'
'when a session reached it, not whether stopping there saved anything.'
