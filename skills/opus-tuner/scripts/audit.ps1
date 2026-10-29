# Session audit. Parses real transcripts and reports where the tokens went.
# This is the measuring instrument: run it before and after any tuning.
#
#   powershell -NoProfile -File audit.ps1                 # newest 10 sessions
#   powershell -NoProfile -File audit.ps1 -Recent 30
#   powershell -NoProfile -File audit.ps1 -Csv out.csv
#   powershell -NoProfile -File audit.ps1 -Baseline baseline.csv
#
# Cache read dominates the token count; cache write and output dominate the
# price. The report shows both so neither gets optimized away by accident.

param(
    [int]$Recent = 10,
    [string]$Project = '',
    [switch]$Json,
    [string]$Csv = '',
    # A CSV written by an earlier run, to print deltas against. Compare against
    # a file from the same parser version: the pre-2x-fix numbers are wrong.
    [string]$Baseline = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$prices = @{
    opus   = @{ In = 15.0; Out = 75.0; Read = 1.50; Write = 18.75 }
    sonnet = @{ In = 3.0;  Out = 15.0; Read = 0.30; Write = 3.75 }
    haiku  = @{ In = 0.80; Out = 4.0;  Read = 0.08; Write = 1.00 }
}

function Get-Family {
    param([string]$Model)
    if ($Model -match 'sonnet') { return 'sonnet' }
    if ($Model -match 'haiku')  { return 'haiku' }
    return 'opus'
}

# Aggregate either the live rows or an imported CSV. Both carry the same column
# names, so one function keeps the two sides of the comparison honest.
function Get-Aggregate {
    param($Rows)
    $readM = 0.0; $cost = 0.0; $req = 0
    $peaks = New-Object System.Collections.ArrayList
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $readM += [double]$r.CacheReadM
        $cost += [double]$r.CostUSD
        $req += [int]$r.Requests
        [void]$peaks.Add([double]$r.PeakCtxK)
    }
    $median = 0.0
    if ($peaks.Count -gt 0) {
        $sorted = @($peaks | Sort-Object)
        $mid = [int][Math]::Floor($sorted.Count / 2)
        if ($sorted.Count % 2 -eq 1) { $median = $sorted[$mid] }
        else { $median = ($sorted[$mid - 1] + $sorted[$mid]) / 2.0 }
    }
    return @{
        sessions   = @($Rows).Count
        requests   = $req
        readM      = $readM
        cost       = $cost
        medianPeak = $median
        perRequest = $(if ($req -gt 0) { $cost / $req } else { 0 })
    }
}

function Format-Delta {
    param([double]$Before, [double]$After)
    if ($Before -eq 0) { return 'n/a' }
    $pct = 100.0 * ($After - $Before) / $Before
    if ($pct -ge 0) { return ('+{0:0}%' -f $pct) }
    return ('{0:0}%' -f $pct)
}

try {
    $root = Join-Path $script:TunerRoot 'projects'
    if ($Project) { $root = Join-Path $root $Project }
    if (-not (Test-Path -LiteralPath $root)) {
        "no transcripts at $root"
        exit 0
    }

    $files = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($Recent -gt 0) { $files = $files | Select-Object -First $Recent }

    $rows = New-Object System.Collections.ArrayList
    $tot = @{ read = [int64]0; write = [int64]0; input = [int64]0; output = [int64]0; req = 0; cost = 0.0 }

    foreach ($f in $files) {
        if ($f.Length -lt 8192) { continue }

        # Not $input: that is PowerShell's automatic variable for piped stdin, and
        # assigning it can block the script when stdin is an open pipe.
        $read = [int64]0; $write = [int64]0; $inTok = [int64]0; $output = [int64]0; $peak = [int64]0
        # Count one usage block per assistant message. A regex over the raw file
        # double counts: `usage` objects nest `iterations` (a repeat of the same
        # counts) and `cache_creation` (a breakdown of cache_creation_input_tokens).
        $models = @{}
        $req = 0
        $reader = [System.IO.StreamReader]::new($f.FullName, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.IndexOf('"usage":') -lt 0) { continue }
                if ($line.IndexOf('"type":"assistant"') -lt 0) { continue }
                $o = $null
                try { $o = $line | ConvertFrom-Json } catch { continue }
                $u = $o.message.usage
                if (-not $u) { continue }
                $r = [int64]$u.cache_read_input_tokens
                $w = [int64]$u.cache_creation_input_tokens
                $i = [int64]$u.input_tokens
                $ot = [int64]$u.output_tokens
                if (($r + $w + $i + $ot) -eq 0) { continue }

                $read += $r; $write += $w; $inTok += $i; $output += $ot
                $req++
                # Context actually sent on this request, which is what the ceiling
                # is measured against - not cache_read alone.
                $ctx = $r + $w + $i
                if ($ctx -gt $peak) { $peak = $ctx }

                $mm = [string]$o.message.model
                if ($mm -and $mm -ne '<synthetic>') {
                    if ($models.ContainsKey($mm)) { $models[$mm]++ } else { $models[$mm] = 1 }
                }
            }
        } finally { $reader.Dispose() }

        if ($req -eq 0) { continue }
        $line = $null
        $dominant = ''
        $best = 0
        foreach ($k in $models.Keys) { if ($models[$k] -gt $best) { $best = $models[$k]; $dominant = $k } }
        $fam = Get-Family $dominant
        $p = $prices[$fam]

        $cost = ($read / 1e6) * $p.Read + ($write / 1e6) * $p.Write +
                ($inTok / 1e6) * $p.In + ($output / 1e6) * $p.Out

        [void]$rows.Add([pscustomobject]@{
            Session    = $f.BaseName.Substring(0, [Math]::Min(8, $f.BaseName.Length))
            MB         = [Math]::Round($f.Length / 1MB, 1)
            Requests   = $req
            CacheReadM = [Math]::Round($read / 1e6, 1)
            CacheWrM   = [Math]::Round($write / 1e6, 1)
            OutputK    = [Math]::Round($output / 1e3, 0)
            PeakCtxK   = [Math]::Round($peak / 1e3, 0)
            Model      = $fam
            CostUSD    = [Math]::Round($cost, 0)
            LastWrite  = $f.LastWriteTime.ToString('MM-dd')
        })

        $tot.read += $read; $tot.write += $write; $tot.input += $inTok; $tot.output += $output
        $tot.req += $req; $tot.cost += $cost
    }

    if ($Json) {
        $payload = @{
            sessions = @($rows)
            totals   = @{
                cacheRead  = $tot.read
                cacheWrite = $tot.write
                input      = $tot.input
                output     = $tot.output
                requests   = $tot.req
                costUSD    = [Math]::Round($tot.cost, 2)
            }
        }
        if ($Baseline -and (Test-Path -LiteralPath $Baseline)) {
            $bRowsJson = @(Import-Csv -LiteralPath $Baseline)
            if ($bRowsJson.Count -gt 0) { $payload['baseline'] = (Get-Aggregate $bRowsJson) }
        }
        Write-HookJson $payload
        exit 0
    }

    if ($Csv) {
        $rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
    }

    $rows | Format-Table -AutoSize

    $totalTokens = $tot.read + $tot.write + $tot.input + $tot.output
    $costRead = ($tot.read / 1e6) * 1.50
    $costWrite = ($tot.write / 1e6) * 18.75
    $costOut = ($tot.output / 1e6) * 75.0
    $costIn = ($tot.input / 1e6) * 15.0

    ''
    "sessions       : $($rows.Count)"
    "requests       : $($tot.req.ToString('N0'))"
    "cache read     : $($tot.read.ToString('N0'))  ($(if ($totalTokens) { [Math]::Round(100.0 * $tot.read / $totalTokens, 1) } else { 0 })% of tokens)"
    "cache write    : $($tot.write.ToString('N0'))"
    "output         : $($tot.output.ToString('N0'))  ($(if ($totalTokens) { [Math]::Round(100.0 * $tot.output / $totalTokens, 2) } else { 0 })% of tokens)"
    "API-equiv cost : `$$($tot.cost.ToString('N0'))"
    ''
    'cost split (opus rates):'
    "  cache read   : `$$([Math]::Round($costRead, 0))"
    "  cache write  : `$$([Math]::Round($costWrite, 0))"
    "  output       : `$$([Math]::Round($costOut, 0))"
    "  fresh input  : `$$([Math]::Round($costIn, 0))"
    ''
    if ($Baseline) {
        if (-not (Test-Path -LiteralPath $Baseline)) {
            "baseline not found: $Baseline"
        } else {
            $bRows = @(Import-Csv -LiteralPath $Baseline)
            $need = @('Requests', 'CacheReadM', 'PeakCtxK', 'CostUSD')
            $missing = @()
            if ($bRows.Count -gt 0) {
                $cols = @($bRows[0].PSObject.Properties.Name)
                $missing = @($need | Where-Object { $cols -notcontains $_ })
            }
            if ($bRows.Count -eq 0 -or $missing.Count -gt 0) {
                "baseline unusable: expected columns $($need -join ', ')"
            } else {
                $b = Get-Aggregate $bRows
                $n = Get-Aggregate $rows
                "baseline comparison ($Baseline)"
                '  metric              baseline          now      change'
                "  sessions        {0,12} {1,12} {2,10}" -f $b.sessions, $n.sessions, (Format-Delta $b.sessions $n.sessions)
                "  requests        {0,12:N0} {1,12:N0} {2,10}" -f $b.requests, $n.requests, (Format-Delta $b.requests $n.requests)
                "  cache read (M)  {0,12:N0} {1,12:N0} {2,10}" -f $b.readM, $n.readM, (Format-Delta $b.readM $n.readM)
                "  median peak (k) {0,12:N0} {1,12:N0} {2,10}" -f $b.medianPeak, $n.medianPeak, (Format-Delta $b.medianPeak $n.medianPeak)
                "  cost (USD)      {0,12:N0} {1,12:N0} {2,10}" -f $b.cost, $n.cost, (Format-Delta $b.cost $n.cost)
                "  cost / request  {0,12:N2} {1,12:N2} {2,10}" -f $b.perRequest, $n.perRequest, (Format-Delta $b.perRequest $n.perRequest)
                ''
                '  peak and cost/request are the signal; total cost also tracks how'
                '  much work the week contained.'
            }
        }
        ''
    }
    'target: cache read share down, peak context down, cost per request down.'
} catch {
    "audit failed: $($_.Exception.Message)"
}
exit 0
