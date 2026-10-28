# Session audit. Parses real transcripts and reports where the tokens went.
# This is the measuring instrument: run it before and after any tuning.
#
#   powershell -NoProfile -File audit.ps1                 # newest 10 sessions
#   powershell -NoProfile -File audit.ps1 -Recent 30
#   powershell -NoProfile -File audit.ps1 -Csv out.csv
#
# Cache read dominates the token count; cache write and output dominate the
# price. The report shows both so neither gets optimized away by accident.

param(
    [int]$Recent = 10,
    [string]$Project = '',
    [switch]$Json,
    [string]$Csv = ''
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

        $read = [int64]0; $write = [int64]0; $input = [int64]0; $output = [int64]0; $peak = [int64]0
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

                $read += $r; $write += $w; $input += $i; $output += $ot
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
                ($input / 1e6) * $p.In + ($output / 1e6) * $p.Out

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

        $tot.read += $read; $tot.write += $write; $tot.input += $input; $tot.output += $output
        $tot.req += $req; $tot.cost += $cost
    }

    if ($Json) {
        Write-HookJson @{
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
    'target: cache read share down, peak context down, cost per request down.'
} catch {
    "audit failed: $($_.Exception.Message)"
}
exit 0
