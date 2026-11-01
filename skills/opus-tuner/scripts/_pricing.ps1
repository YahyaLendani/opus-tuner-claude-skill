# Prices one transcript request from a versioned table. Dot-sourced by audit.ps1
# and the benchmark report, not by hooks: hooks never need a dollar figure, and
# every script a hook loads adds to its parse time.
#
# A price is only ever an exact match. A model the table does not name stays
# unknown instead of borrowing a family's rate, because a new model in a known
# family has not always kept its family's price.

$script:PricingError = ''

# Order: an explicit path, the config's pricingFile, the bundled table. A path that
# was asked for and does not work is an error, not a reason to use different prices.
function Get-PricingTable {
    param([string]$Path = '', $Config = $null)
    $script:PricingError = ''
    $file = $Path
    if (-not $file -and $Config -and $Config['pricingFile']) { $file = [string]$Config['pricingFile'] }
    if (-not $file) { $file = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'references') 'pricing.json' }
    if (-not (Test-Path -LiteralPath $file)) {
        $script:PricingError = "pricing table not found: $file"
        return $null
    }
    $table = $null
    try { $table = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json } catch {
        $script:PricingError = "could not read the pricing table: $file"
        return $null
    }
    if ($null -eq $table -or $table.schema -ne 1 -or -not [string]$table.version -or $null -eq $table.models) {
        $script:PricingError = "could not use the pricing table, it needs schema 1, a version and models: $file"
        return $null
    }
    return $table
}

# The name a table lists a model under, whichever provider or suffix it arrived
# with: us.anthropic.claude-sonnet-4-5-20250929-v1:0, claude-opus-4-8@20260101 and
# claude-opus-5-5[1m] all come down to the bare id.
function ConvertTo-PricingModel {
    param([string]$Model, $Table = $null)
    $m = ([string]$Model).Trim().ToLowerInvariant()
    $m = $m -replace '^(?:[a-z]+\.)?anthropic\.', ''
    $m = $m -replace '\[[^\]]*\]$', ''
    $m = $m -replace '-v\d+(?::\d+)?$', ''
    $m = $m -replace '@.*$', ''
    $m = $m -replace '-latest$', ''
    $m = $m -replace '-\d{8}$', ''
    if ($Table -and $Table.aliases) {
        $alias = $Table.aliases.PSObject.Properties[$m]
        if ($alias) { $m = [string]$alias.Value }
    }
    return $m
}

# What one request cost at list prices, in [decimal] so that summing many small
# figures loses nothing. known is $false, with a reason, when the table cannot say.
function Get-RequestCost {
    param($Record, $Table)
    $zero = [decimal]0
    $result = @{
        known = $false; reason = ''; model = ''; cost = $zero
        input = $zero; read = $zero; write = $zero; output = $zero
        assumedWriteTokens = [int64]0
    }
    if ($null -eq $Table) { $result.reason = 'no pricing table'; return $result }

    $name = ConvertTo-PricingModel $Record.model $Table
    $result.model = $name
    $hit = $Table.models.PSObject.Properties[$name]
    if (-not $hit) { $result.reason = 'not in the pricing table'; return $result }
    $entry = $hit.Value

    $rates = @{}
    foreach ($field in @('input', 'output', 'cacheRead', 'cacheWrite5m', 'cacheWrite1h')) {
        if ($null -eq $entry.$field) { $result.reason = "no $field rate"; return $result }
        $rates[$field] = [decimal]$entry.$field
    }

    # Priced by the whole prompt, cached or not, and only strictly over the line.
    $long = $entry.longPrompt
    if ($long -and ($Record.input + $Record.cacheRead + $Record.cacheWrite) -gt [int64]$long.thresholdTokens) {
        foreach ($field in @($rates.Keys)) {
            if ($null -eq $long.$field) { $result.reason = "no long-prompt $field rate"; return $result }
            $rates[$field] = [decimal]$long.$field
        }
    }

    # Cache rates are multiples of the input rate, so they scale with fast mode.
    if ($Record.speed -eq 'fast') {
        $fast = $entry.fast
        if (-not $fast) { $result.reason = 'no fast rate'; return $result }
        $scale = ([decimal]$fast.input) / $rates.input
        $rates.cacheRead *= $scale
        $rates.cacheWrite5m *= $scale
        $rates.cacheWrite1h *= $scale
        $rates.input = [decimal]$fast.input
        $rates.output = [decimal]$fast.output
    }

    $geo = [decimal]1
    if ($Record.geo -and $entry.geoPremium -eq $true -and $Table.geoMultipliers) {
        $m = $Table.geoMultipliers.PSObject.Properties[[string]$Record.geo]
        if ($m) { $geo = [decimal]$m.Value }
    }

    # Older records report one cache-write total with no 5m and 1h breakdown. The
    # 5m rate is the lower of the two, so this assumption can only undercount.
    $assumed = $Record.cacheWrite - $Record.write5m - $Record.write1h
    if ($assumed -lt 0) { $assumed = [int64]0 }

    $million = [decimal]1000000
    $result.input = ([decimal]$Record.input) * $rates.input * $geo / $million
    $result.read = ([decimal]$Record.cacheRead) * $rates.cacheRead * $geo / $million
    $result.write = ((([decimal]$Record.write5m + [decimal]$assumed) * $rates.cacheWrite5m) + (([decimal]$Record.write1h) * $rates.cacheWrite1h)) * $geo / $million
    $result.output = ([decimal]$Record.output) * $rates.output * $geo / $million
    $result.cost = $result.input + $result.read + $result.write + $result.output
    $result.assumedWriteTokens = [int64]$assumed
    $result.known = $true
    return $result
}
