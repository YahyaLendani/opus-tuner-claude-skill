# Session audit. Parses real transcripts and reports where the tokens went.
# This is the measuring instrument: run it before and after any tuning.
#
#   powershell -NoProfile -File audit.ps1                 # newest 10 sessions
#   powershell -NoProfile -File audit.ps1 -Recent 30
#   powershell -NoProfile -File audit.ps1 -Csv out.csv
#   powershell -NoProfile -File audit.ps1 -Baseline baseline.csv
#   powershell -NoProfile -File audit.ps1 -Pricing my-prices.json
#
# Each request is priced at its own model's list price from a versioned table.
# The result is an API-equivalent estimate, not a bill: it says nothing about what
# a subscription charged or how close it is to its limits.

param(
    [int]$Recent = 10,
    [string]$Project = '',
    [switch]$Json,
    [string]$Csv = '',
    # A CSV written by an earlier run, to print deltas against.
    [string]$Baseline = '',
    # A table in the format of references/pricing.json. Overrides pricingFile.
    [string]$Pricing = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_pricing.ps1')

$script:EstimateLabel = 'API-equivalent estimate at list prices. It is not your bill or your subscription limits.'

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

function Format-Cost {
    param([decimal]$Value)
    return '$' + $Value.ToString('N2')
}

# "high:2 xhigh:1" from a name-to-count table.
function Format-Counts {
    param($Counts)
    return (@($Counts.Keys | Sort-Object | ForEach-Object { "${_}:$($Counts[$_])" }) -join ' ')
}

function Add-Count {
    param($Counts, [string]$Key)
    if ($Counts.ContainsKey($Key)) { $Counts[$Key]++ } else { $Counts[$Key] = 1 }
}

try {
    $root = Join-Path $script:TunerRoot 'projects'
    if ($Project) { $root = Join-Path $root $Project }
    if (-not (Test-Path -LiteralPath $root)) {
        "no transcripts at $root"
        exit 0
    }

    $table = Get-PricingTable -Path $Pricing -Config (Get-TunerConfig)
    $pricingVersion = if ($table) { [string]$table.version } else { '' }

    $files = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($Recent -gt 0) { $files = $files | Select-Object -First $Recent }
    # Oldest first, so that a record a resumed session replays stays with the
    # session that made the request.
    $files = @($files)
    [array]::Reverse($files)

    # One assistant message spans many transcript lines, each repeating its usage,
    # and a resumed session copies old lines into a new file. Case-sensitive, since
    # ids are. Streamed copies of a message can differ, so each count keeps its largest.
    $seen = New-Object System.Collections.Hashtable
    $records = New-Object System.Collections.ArrayList
    $duplicates = 0
    $unreadableFiles = 0
    for ($n = 0; $n -lt $files.Count; $n++) {
        $stream = $null
        # Shared for write and delete: the newest transcript is usually still live.
        try { $stream = [System.IO.File]::Open($files[$n].FullName, 'Open', 'Read', 'ReadWrite, Delete') }
        catch { $unreadableFiles++; continue }
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            while ($null -ne ($line = $reader.ReadLine())) {
                $rec = Read-UsageRecord -Line $line
                if ($null -eq $rec -or $rec.model -eq '<synthetic>') { continue }
                $key = $rec.messageId
                if (-not $key) { $key = $rec.requestId }
                if (-not $key) { $key = $rec.uuid }
                if ($key -and $seen.ContainsKey($key)) {
                    $first = $seen[$key]
                    foreach ($field in @('input', 'output', 'cacheRead', 'cacheWrite', 'write5m', 'write1h')) {
                        if ($rec[$field] -gt $first[$field]) { $first[$field] = $rec[$field] }
                    }
                    $duplicates++
                    continue
                }
                if ($key) { $seen[$key] = $rec }
                $rec['file'] = $n
                [void]$records.Add($rec)
            }
        } finally { $stream.Dispose() }
    }

    $zero = [decimal]0
    $sessions = @{}
    $tot = @{
        read = [int64]0; write = [int64]0; input = [int64]0; output = [int64]0; req = 0
        cost = $zero; costRead = $zero; costWrite = $zero; costInput = $zero; costOutput = $zero
        unknown = 0; assumed = [int64]0; mismatches = 0
    }
    $unknownModels = @{}
    $effortTotals = @{}

    foreach ($rec in $records) {
        if (($rec.input + $rec.output + $rec.cacheRead + $rec.cacheWrite) -eq 0) { continue }
        $s = $sessions[$rec.file]
        if ($null -eq $s) {
            $s = @{
                read = [int64]0; write = [int64]0; output = [int64]0; req = 0
                peakMain = [int64]0; peakAny = [int64]0; cost = $zero; unknown = 0
                assumed = [int64]0; mismatches = 0; models = @{}; effort = @{}
            }
            $sessions[$rec.file] = $s
        }
        $s.read += $rec.cacheRead; $s.write += $rec.cacheWrite; $s.output += $rec.output
        $s.req++
        $tot.read += $rec.cacheRead; $tot.write += $rec.cacheWrite
        $tot.input += $rec.input; $tot.output += $rec.output
        $tot.req++

        # Context actually sent on this request, which is what the ceiling is
        # measured against - not cache_read alone. A subagent's requests are billed
        # but are not this session's context.
        $ctx = $rec.input + $rec.cacheRead + $rec.cacheWrite
        if ($ctx -gt $s.peakAny) { $s.peakAny = $ctx }
        if (-not $rec.isSidechain -and $ctx -gt $s.peakMain) { $s.peakMain = $ctx }

        Add-Count $s.models $rec.model
        $effort = if ($rec.perTurnEffort) { $rec.perTurnEffort } else { $rec.effort }
        if ($effort) { Add-Count $s.effort $effort; Add-Count $effortTotals $effort }

        # An alias such as "opus" says nothing about which version was meant.
        $wanted = ConvertTo-PricingModel $rec.requestedModel $table
        if ($wanted -like 'claude-*' -and $wanted -ne (ConvertTo-PricingModel $rec.model $table)) {
            $s.mismatches++
            $tot.mismatches++
        }

        $c = Get-RequestCost $rec $table
        if ($c.known) {
            $s.cost += $c.cost
            $s.assumed += $c.assumedWriteTokens
            $tot.cost += $c.cost
            $tot.costRead += $c.read; $tot.costWrite += $c.write
            $tot.costInput += $c.input; $tot.costOutput += $c.output
            $tot.assumed += $c.assumedWriteTokens
        } else {
            $s.unknown++
            $tot.unknown++
            $label = $rec.model
            if ($rec.speed -eq 'fast') { $label += ' (fast)' }
            $unknownModels[$label] = $true
        }
    }

    # Newest first. Numbers stay unrounded here, and only the printed table rounds.
    $rows = New-Object System.Collections.ArrayList
    for ($n = $files.Count - 1; $n -ge 0; $n--) {
        $s = $sessions[$n]
        if ($null -eq $s) { continue }
        $f = $files[$n]
        $peak = if ($s.peakMain -gt 0) { $s.peakMain } else { $s.peakAny }
        [void]$rows.Add([pscustomobject]@{
            Session            = $f.BaseName.Substring(0, [Math]::Min(8, $f.BaseName.Length))
            MB                 = $f.Length / 1MB
            Requests           = $s.req
            CacheReadM         = $s.read / 1e6
            CacheWrM           = $s.write / 1e6
            OutputK            = $s.output / 1e3
            PeakCtxK           = $peak / 1e3
            Models             = Format-Counts $s.models
            CostUSD            = $(if ($table) { $s.cost } else { $null })
            UnknownRequests    = $s.unknown
            AssumedWriteTokens = $s.assumed
            ModelMismatches    = $s.mismatches
            Effort             = Format-Counts $s.effort
            PricingVersion     = $pricingVersion
            LastWrite          = $f.LastWriteTime.ToString('MM-dd')
        })
    }
    $unknownNames = @($unknownModels.Keys | Sort-Object)

    if ($Json) {
        $payload = @{
            sessions = @($rows)
            totals   = @{
                cacheRead  = $tot.read
                cacheWrite = $tot.write
                input      = $tot.input
                output     = $tot.output
                requests   = $tot.req
                costUSD    = $(if ($table) { $tot.cost } else { $null })
                costSplit  = $(if ($table) { @{ cacheRead = $tot.costRead; cacheWrite = $tot.costWrite; input = $tot.costInput; output = $tot.costOutput } } else { $null })
            }
            pricingVersion          = $(if ($table) { $pricingVersion } else { $null })
            pricingError            = $script:PricingError
            estimateLabel           = $script:EstimateLabel
            unknownPricing          = @{ requests = $tot.unknown; models = $unknownNames }
            assumedCacheWriteTokens = $tot.assumed
            duplicateRecords        = $duplicates
            unparsedLines           = $script:UsageParseFailures
            unreadableFiles         = $unreadableFiles
            modelMismatches         = $tot.mismatches
            effort                  = $effortTotals
        }
        if ($Baseline -and (Test-Path -LiteralPath $Baseline)) {
            $bRowsJson = @(Import-Csv -LiteralPath $Baseline)
            if ($bRowsJson.Count -gt 0) { $payload['baseline'] = (Get-Aggregate $bRowsJson) }
        }
        Write-HookJson $payload
        exit 0
    }

    # Invariant text, so a baseline written under one locale reads back the same
    # under another.
    if ($Csv) {
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $rows | ForEach-Object {
            $out = [ordered]@{}
            foreach ($p in $_.PSObject.Properties) {
                if ($p.Value -is [System.IFormattable]) { $out[$p.Name] = $p.Value.ToString($null, $invariant) }
                else { $out[$p.Name] = $p.Value }
            }
            [pscustomobject]$out
        } | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
    }

    $rows | ForEach-Object {
        $shown = 'n/a'
        if ($table -and $_.Requests -gt $_.UnknownRequests) {
            $shown = ([decimal]$_.CostUSD).ToString('N2')
            if ($_.UnknownRequests -gt 0) { $shown = ">=$shown" }
        }
        [pscustomobject]@{
            Session    = $_.Session
            MB         = [Math]::Round($_.MB, 1)
            Requests   = $_.Requests
            CacheReadM = [Math]::Round($_.CacheReadM, 1)
            CacheWrM   = [Math]::Round($_.CacheWrM, 1)
            OutputK    = [Math]::Round($_.OutputK, 0)
            PeakCtxK   = [Math]::Round($_.PeakCtxK, 0)
            CostUSD    = $shown
            LastWrite  = $_.LastWrite
            Models     = ($_.Models -replace 'claude-', '')
        }
    } | Format-Table -AutoSize | Out-String -Width 240

    $totalTokens = $tot.read + $tot.write + $tot.input + $tot.output
    "sessions       : $($rows.Count)"
    "requests       : $($tot.req.ToString('N0'))"
    "cache read     : $($tot.read.ToString('N0'))  ($(if ($totalTokens) { [Math]::Round(100.0 * $tot.read / $totalTokens, 1) } else { 0 })% of tokens)"
    "cache write    : $($tot.write.ToString('N0'))"
    "output         : $($tot.output.ToString('N0'))  ($(if ($totalTokens) { [Math]::Round(100.0 * $tot.output / $totalTokens, 2) } else { 0 })% of tokens)"
    "fresh input    : $($tot.input.ToString('N0'))"
    if ($duplicates -gt 0) { "duplicates     : $($duplicates.ToString('N0')) repeated transcript record(s) counted once" }
    if ($script:UsageParseFailures -gt 0) { "unreadable     : $($script:UsageParseFailures) line(s) that look like usage would not parse, and are not counted" }
    if ($unreadableFiles -gt 0) { "unreadable     : $unreadableFiles transcript file(s) could not be opened, and are not counted" }
    if ($tot.mismatches -gt 0) { "model changes  : $($tot.mismatches) request(s) served by a different model than requested" }
    if ($effortTotals.Count -gt 0) { "effort         : $(Format-Counts $effortTotals), as the transcript reports it" }
    ''
    if ($table) {
        "$($script:EstimateLabel)"
        "  total        : $(Format-Cost $tot.cost)  (pricing table $pricingVersion)"
        "  cache read   : $(Format-Cost $tot.costRead)"
        "  cache write  : $(Format-Cost $tot.costWrite)"
        "  output       : $(Format-Cost $tot.costOutput)"
        "  fresh input  : $(Format-Cost $tot.costInput)"
        if ($tot.unknown -gt 0) {
            "  lower bound  : $($tot.unknown) request(s) have no known price and add nothing to the total: $($unknownNames -join ', ')"
        }
        if ($tot.assumed -gt 0) {
            "  assumed      : $($tot.assumed.ToString('N0')) cache-write token(s) had no 5m or 1h breakdown, and were priced at the 5m rate"
        }
    } else {
        "No cost estimate, pricing unavailable: $($script:PricingError)"
        '  The token counts above do not depend on it.'
    }
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
                "  cache read (M)  {0,12:N1} {1,12:N1} {2,10}" -f $b.readM, $n.readM, (Format-Delta $b.readM $n.readM)
                "  median peak (k) {0,12:N0} {1,12:N0} {2,10}" -f $b.medianPeak, $n.medianPeak, (Format-Delta $b.medianPeak $n.medianPeak)
                if ($table) {
                    "  cost (USD)      {0,12:N2} {1,12:N2} {2,10}" -f $b.cost, $n.cost, (Format-Delta $b.cost $n.cost)
                    "  cost / request  {0,12:N4} {1,12:N4} {2,10}" -f $b.perRequest, $n.perRequest, (Format-Delta $b.perRequest $n.perRequest)
                }
                ''
                '  total cost also tracks how much work each period contained, so it'
                '  cannot show a saving alone. Tasks differ between periods; for a fair'
                '  comparison use the benchmark harness.'
                $bVersions = @($bRows | ForEach-Object { $_.PSObject.Properties['PricingVersion'] } | Where-Object { $_ -and $_.Value } | ForEach-Object { $_.Value } | Sort-Object -Unique)
                if ($bVersions.Count -eq 0) {
                    ''
                    '  this baseline has no pricing version, so it was written before 0.7. It'
                    '  priced whole sessions at one rate and counted repeated records, so its'
                    '  figures run higher than these for the same work. Treat any change as unproven.'
                } elseif ($table -and ($bVersions.Count -gt 1 -or $bVersions[0] -ne $pricingVersion)) {
                    ''
                    "  this baseline used pricing version $($bVersions -join ', '), and now uses $pricingVersion. Costs can differ with prices alone."
                }
            }
        }
        ''
    }
    'to compare: save a run with -Csv before a change, then pass that file to -Baseline after it.'
} catch {
    "audit failed: $($_.Exception.Message)"
}
exit 0
